# pg_stat_role — cumulative per-role resource usage statistics

`pg_stat_role` accumulates, per role, the resources consumed by SQL
statements: statement and row counts, wall-clock execution time, CPU
time, block I/O and WAL usage.  It fills a gap PostgreSQL has compared
with other systems (Oracle `v$sesstat` aggregations, MySQL
`performance_schema` by-user summaries, MariaDB `userstat`, SQL Server
`dm_exec_sessions`): PostgreSQL's per-backend statistics
(`PGSTAT_KIND_BACKEND`, PG18) are discarded when the backend exits and
are never aggregated to a longer-lived object such as a role.

The module is a prototype for a possible in-core `PGSTAT_KIND_ROLE`,
implemented as a standalone extension on top of the *custom cumulative
statistics* infrastructure introduced in PostgreSQL 18
(`pgstat_register_kind`).  It therefore requires **PostgreSQL 18 or
later** and must be loaded via `shared_preload_libraries`.

## Usage

```
shared_preload_libraries = 'pg_stat_role'
```

```sql
CREATE EXTENSION pg_stat_role;

SELECT rolname, statements, rows, total_exec_time,
       cpu_user_time, cpu_system_time,
       shared_blks_hit, shared_blks_read, wal_bytes
  FROM pg_stat_role;
```

### Objects

- **View `pg_stat_role`** — one row per role that has executed
  statements since the last reset, joined with `pg_roles` for
  `rolname`.  Columns:

  | column | description |
  | --- | --- |
  | `roleid`, `rolname` | role identity (`rolname` is NULL if the role was dropped and the entry not yet cleaned up) |
  | `statements` | top-level statements executed |
  | `rows` | rows retrieved or affected |
  | `total_exec_time` | wall-clock execution time, in ms |
  | `cpu_user_time`, `cpu_system_time` | CPU time from `getrusage(RUSAGE_SELF)`, in ms |
  | `vol_context_switches`, `invol_context_switches` | context switches (0 on Windows, whose `getrusage()` port only reports CPU time) |
  | `shared_blks_hit/read/dirtied/written` | shared-buffer usage |
  | `local_blks_hit/read/dirtied/written` | local-buffer usage (temp tables) |
  | `temp_blks_read/written` | temp-file block I/O |
  | `wal_records`, `wal_fpi`, `wal_bytes` | WAL generated |
  | `stats_reset` | last reset time of this entry |

- **`pg_stat_role_reset(roleid oid DEFAULT NULL)`** — reset one role's
  counters, or all of them when called with NULL.
- **`pg_stat_role_gc() → bigint`** — drop entries whose role no longer
  exists in `pg_authid` (safety net for drops that bypassed the
  extension, e.g. while it was not loaded); returns the number of
  entries removed.
- **GUC `pg_stat_role.track`** (bool, default `on`, superuser) —
  enables/disables collection.

### Permissions

Per-role resource consumption can leak information about other tenants'
activity, so — following the convention of the per-backend statistics
views — `SELECT` on the view (and on the underlying
`pg_stat_role_entries()` function) is granted only to
`pg_read_all_stats`.  `pg_stat_role_reset()` and `pg_stat_role_gc()`
are not granted to anyone by default.

## Design decisions

- **Statistics key**: variable-numbered custom stats kind with key
  `(dboid = InvalidOid, objid = role OID)`, i.e. a cluster-wide
  aggregate per role.  A two-dimensional database×role key is left for
  a later iteration.
- **Attribution**: an entire statement is charged to the user returned
  by `GetUserId()` at statement start — the same call
  `pg_stat_statements` uses for its `userid` column.  Resources
  consumed inside `SECURITY DEFINER` functions are charged to the
  *caller*, not the function owner; no attempt is made to split a
  statement across user-id switches.
- **Collection**: `ExecutorStart`/`ExecutorEnd` and `ProcessUtility`
  hooks compute per-statement deltas of `getrusage(RUSAGE_SELF)`,
  `pgBufferUsage` and `pgWalUsage` (the `pg_stat_statements` /
  `pg_stat_kcache` scheme).  Only top-level statements are measured;
  a nesting-level counter prevents SQL inside functions or utility
  commands from being counted twice.  Deltas accumulate in a
  backend-local pending entry and are flushed through the standard
  cumulative-statistics machinery (`flush_pending_cb`), i.e. at most
  roughly once per second per backend, which also bounds contention on
  the shared entry when many connections run as the same role.
- **Parallel queries**: worker processes execute the executor hooks
  too.  A worker's buffer and WAL usage is already propagated to the
  leader (`InstrAccumParallelQuery`), so workers record *only* CPU time
  and context switches — the one thing the leader's `getrusage()`
  cannot see — and do not bump statement/row/buffer/WAL counters.
- **Persistence**: entries are serialized into the standard pgstats
  file (`write_to_file = true`), so counters survive clean restarts;
  like all cumulative statistics they are lost on crash.
- **DROP ROLE**: an `object_access_hook` (`OAT_DROP` on
  `AuthIdRelationId`) registers a transactional drop of the entry, so
  a rolled-back `DROP ROLE` keeps its statistics.

## Known limitations

- **Kind ID**: the module currently uses `PGSTAT_KIND_EXPERIMENTAL`
  (24), the shared ID for in-development extensions.  It will collide
  with any other extension using the same ID (e.g. the
  `test_custom_stats` modules); a unique ID should be requested via
  <https://wiki.postgresql.org/wiki/CustomCumulativeStats> before real
  use.
- CPU time of auxiliary parallel workers that do not run the executor
  (parallel `CREATE INDEX` / `VACUUM` workers) is not captured, and
  background processing (autovacuum, checkpointer, WAL writer) is not
  attributed to any role.
- Statements that fail with an error are not counted (the
  `ExecutorEnd` hook is never reached), matching `pg_stat_statements`.
- With cursors and interleaved portal execution (extended query
  protocol), work performed while another top-level statement is being
  tracked may be attributed to that statement, or dropped for the
  suspended portal; `FETCH` statements themselves are measured as
  utility statements.  `pg_stat_kcache` has the same limitation.
- On Windows, `vol_context_switches`/`invol_context_switches` stay 0
  (`src/port/win32getrusage.c` only fills in CPU times).
- `wal_bytes` is exposed as `numeric` (internally `uint64`); the other
  counters are `bigint`.

## Benchmarks

`pgbench -S` (select-only, scale 10, 10 s runs, best of 2 rounds), all
clients connecting as the same role — the worst case for both
per-statement overhead (many tiny statements) and shared-entry
contention.  Run on a 4-core container against an assert-enabled
(`cassert`) build, so treat the numbers as indicative only:

| clients | track=on (tps) | track=off (tps) | delta |
| ---: | ---: | ---: | ---: |
| 1 | 5190 | 5443 | −4.6% |
| 4 | 34743 | 34542 | +0.6% |
| 16 | 26706 | 27291 | −2.1% |
| 32 | 26823 | 27069 | −0.9% |

The single-client delta is the per-statement bookkeeping (two
`getrusage()` calls plus clock reads per statement); at higher client
counts the difference is within run-to-run noise, and throughput shows
no collapse when 32 clients hammer the same shared entry — as expected,
since each backend flushes its pending deltas at most about once per
second.  A proper multi-socket benchmark on an optimized build should
accompany any in-core proposal.

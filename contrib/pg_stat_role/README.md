# pg_stat_role

**Cumulative per-role resource usage statistics for PostgreSQL 18+.**

`pg_stat_role` accumulates, per database role, the resources consumed
by SQL statements: statement and row counts, wall-clock execution
time, CPU time, context switches, block I/O and WAL usage. Counters
survive server restarts and are exposed through a single view:

```sql
SELECT rolname, statements, rows,
       round(total_exec_time::numeric, 1)  AS exec_ms,
       round(cpu_user_time::numeric, 1)    AS cpu_user_ms,
       round(cpu_system_time::numeric, 1)  AS cpu_sys_ms,
       shared_blks_hit, shared_blks_read, wal_bytes
  FROM pg_stat_role
 ORDER BY total_exec_time DESC;

   rolname   | statements | rows  | exec_ms | cpu_user_ms | cpu_sys_ms | shared_blks_hit | shared_blks_read | wal_bytes
-------------+------------+-------+---------+-------------+------------+-----------------+------------------+-----------
 app_batch   |       1284 | 95210 |  8123.4 |      5710.2 |      312.9 |          402188 |            10331 |  52023840
 app_web     |      55811 | 61240 |  2984.7 |      1211.0 |      189.4 |          822401 |              215 |   1002812
 reporting   |         12 | 30500 |  1450.2 |       955.1 |       48.7 |          120553 |            84210 |         0
```

## Status

**Experimental.** This module is a working prototype for a possible
in-core `PGSTAT_KIND_ROLE`, built on the *custom cumulative
statistics* API introduced in PostgreSQL 18
(`pgstat_register_kind`). It currently uses the shared
`PGSTAT_KIND_EXPERIMENTAL` kind ID (24), so it cannot be loaded
together with another extension using that same ID; a unique ID will
be requested via the
[Custom Cumulative Stats registry](https://wiki.postgresql.org/wiki/CustomCumulativeStats)
before a stable release.

## Why

Most database systems can answer "which user consumed how much"
directly from a built-in view — Oracle (`v$sesstat` aggregations),
MySQL (`performance_schema` by-user summaries), MariaDB (`userstat`),
SQL Server (`dm_exec_sessions`). PostgreSQL cannot: the per-backend
statistics added in PostgreSQL 18 (`pg_stat_get_backend_io()` and
friends) are discarded when a backend exits and are never aggregated
to a longer-lived object such as a role. `pg_stat_statements` comes
closest, but it aggregates by query, is bounded by `pgss_max`, and
does not track CPU. `pg_stat_role` fills that gap with a small,
always-on, per-role aggregate.

## Requirements

- PostgreSQL **18 or later** (the custom cumulative statistics API is
  required).
- The library must be loaded via `shared_preload_libraries`.
- Any platform PostgreSQL runs on. On Windows, CPU times are
  collected but context-switch counters stay 0 (the `getrusage()`
  port only reports CPU time).

## Installation

### Standalone, against an installed PostgreSQL (PGXS)

```sh
make USE_PGXS=1
make USE_PGXS=1 install    # may need sudo
```

`pg_config` must be in `PATH` (or pass
`PG_CONFIG=/path/to/pg_config`).

### Inside a PostgreSQL source tree

Place this directory at `contrib/pg_stat_role` and add it to the
contrib lists (`contrib/Makefile`, `contrib/meson.build`); it then
builds and tests like any other contrib module with both make and
meson.

### Enable it

```
# postgresql.conf
shared_preload_libraries = 'pg_stat_role'
```

Restart the server, then in one database:

```sql
CREATE EXTENSION pg_stat_role;
```

Statistics are collected cluster-wide as soon as the library is
loaded; the extension objects (view and functions) are just the SQL
interface to them and can be created in any database.

## The `pg_stat_role` view

One row per role that has executed statements since its entry was
created. `rolname` is NULL if the role was dropped but its entry has
not been cleaned up yet (see `pg_stat_role_gc`).

| Column | Type | Description |
| --- | --- | --- |
| `roleid` | `oid` | OID of the role |
| `rolname` | `name` | Name of the role |
| `statements` | `bigint` | Top-level statements executed |
| `rows` | `bigint` | Rows retrieved or affected |
| `total_exec_time` | `double precision` | Wall-clock statement execution time, in ms |
| `cpu_user_time` | `double precision` | User CPU time (`getrusage`), in ms |
| `cpu_system_time` | `double precision` | System CPU time (`getrusage`), in ms |
| `vol_context_switches` | `bigint` | Voluntary context switches (0 on Windows) |
| `invol_context_switches` | `bigint` | Involuntary context switches (0 on Windows) |
| `shared_blks_hit` / `read` / `dirtied` / `written` | `bigint` | Shared-buffer usage |
| `local_blks_hit` / `read` / `dirtied` / `written` | `bigint` | Local-buffer usage (temporary tables) |
| `temp_blks_read` / `written` | `bigint` | Temp-file block I/O |
| `wal_records` / `wal_fpi` | `bigint` | WAL records / full-page images generated |
| `wal_bytes` | `numeric` | WAL bytes generated |
| `stats_reset` | `timestamptz` | Last reset time of this entry |

## Functions and configuration

| Object | Description |
| --- | --- |
| `pg_stat_role_reset(roleid oid DEFAULT NULL)` | Reset one role's counters, or all of them when called with NULL. |
| `pg_stat_role_gc() → bigint` | Drop entries whose role no longer exists in `pg_authid` and return how many were removed. Entries are normally dropped by `DROP ROLE` itself; this is a safety net, e.g. for roles dropped while the library was not loaded. |
| `pg_stat_role_entries()` | Set-returning function underlying the view. |
| GUC `pg_stat_role.track` | `on`/`off` (default `on`), superuser-settable at runtime. |

### Permissions

Per-role resource consumption can reveal what other tenants are doing,
so — following the convention of PostgreSQL's per-backend statistics
views — `SELECT` on the view and on `pg_stat_role_entries()` is
granted only to `pg_read_all_stats`. `pg_stat_role_reset()` and
`pg_stat_role_gc()` are executable only by superusers unless
explicitly granted.

## Design notes

- **Statistics key.** A variable-numbered custom stats kind keyed by
  `(dboid = InvalidOid, objid = role OID)`: one cluster-wide entry per
  role. A two-dimensional database×role key is a possible later
  extension.
- **Attribution.** An entire statement is charged to the user returned
  by `GetUserId()` at statement start — the same call
  `pg_stat_statements` uses for its `userid` column. Resources
  consumed inside `SECURITY DEFINER` functions are therefore charged
  to the *caller*, not the function owner; no attempt is made to split
  a statement across user-id switches. Note the corollary that a
  `RESET ROLE` / `SET ROLE none` statement is charged to the role
  being abandoned.
- **Collection.** `ExecutorStart`/`ExecutorEnd` and `ProcessUtility`
  hooks compute per-statement deltas of `getrusage(RUSAGE_SELF)`,
  `pgBufferUsage` and `pgWalUsage` — the same scheme as
  `pg_stat_statements` and `pg_stat_kcache`. Only top-level statements
  are measured; a nesting-level counter ensures SQL executed inside
  functions or utility commands is charged once, to the enclosing
  statement.
- **Flushing.** Deltas accumulate in a backend-local pending entry and
  are flushed through the standard cumulative-statistics machinery
  (`flush_pending_cb`) — at most roughly once per second per backend,
  which also bounds lock contention on the shared entry when many
  connections run as the same role (see Benchmarks).
- **Parallel queries.** Worker processes run the executor hooks too. A
  worker's buffer and WAL usage is already propagated to the leader
  (`InstrAccumParallelQuery`), so workers record *only* CPU time and
  context switches — the one thing the leader's `getrusage()` cannot
  see — and never bump statement/row/buffer/WAL counters.
- **Persistence.** Entries are serialized into the standard pgstats
  file (`write_to_file = true`) and restored at startup, so counters
  survive clean restarts. Like all PostgreSQL cumulative statistics,
  they are lost after a crash.
- **`DROP ROLE`.** An `object_access_hook` (`OAT_DROP` on
  `pg_authid`) registers a *transactional* drop of the entry: a
  rolled-back `DROP ROLE` keeps its statistics.

## Known limitations

- The `PGSTAT_KIND_EXPERIMENTAL` kind ID collides with any other
  in-development custom-stats extension loaded at the same time (for
  example PostgreSQL's own `test_custom_stats` test modules).
- CPU time of parallel workers that do not go through the executor
  (parallel `CREATE INDEX`, parallel `VACUUM`) is not captured — their
  buffer and WAL usage *is*, via the leader. This is a limitation of
  the current hook placement, not of the statistics API; see Roadmap.
- Background processing (autovacuum, checkpointer, WAL writer,
  bgwriter) is not attributed to any role.
- Statements that fail with an error are not counted (`ExecutorEnd`
  is never reached), matching `pg_stat_statements`.
- With cursors and interleaved portal execution (extended query
  protocol), work performed while another top-level statement is being
  tracked may be attributed to that statement or dropped for the
  suspended portal; `FETCH` statements themselves are measured as
  utility statements. `pg_stat_kcache` shares this limitation.

## Overhead

`pgbench -S` (select-only, scale 10, 10 s runs, best of 2 rounds), all
clients connecting as the same role — the worst case for both
per-statement overhead (many tiny statements) and shared-entry
contention. Measured on a 4-core container against an assert-enabled
(`--buildtype=debugoptimized -Dcassert=true`) build, so treat the
numbers as indicative only:

| clients | track=on (tps) | track=off (tps) | delta |
| ---: | ---: | ---: | ---: |
| 1 | 5190 | 5443 | −4.6% |
| 4 | 34743 | 34542 | +0.6% |
| 16 | 26706 | 27291 | −2.1% |
| 32 | 26823 | 27069 | −0.9% |

The single-client delta is the per-statement bookkeeping (two
`getrusage()` calls plus clock reads per statement); at higher client
counts the difference is within run-to-run noise, and throughput shows
no collapse when 32 clients hammer the same shared entry — as
expected, given the batched pending flushes. A proper multi-socket
benchmark on an optimized build should accompany any in-core proposal.

## Testing

Inside a PostgreSQL source tree:

```sh
meson test pg_stat_role/regress        # meson build
make -C contrib/pg_stat_role check     # autoconf build
```

Standalone, against a running server that already has
`shared_preload_libraries = 'pg_stat_role'`:

```sh
make USE_PGXS=1 installcheck
```

The regression suite covers attribution across `SET ROLE`, privilege
enforcement, nested statements, `SECURITY DEFINER`, parallel query
double-count protection, `pg_stat_role.track`, per-role and global
reset, and `DROP ROLE` cleanup (including rollback).

## Roadmap

- Reserve a permanent custom stats kind ID.
- Capture CPU time of executor-less parallel workers: the custom-stats
  `init_backend_cb` runs in every process attached to the statistics
  system (parallel workers included), so a process-exit flush of
  whole-process `getrusage()` can cover them; an in-core
  implementation would instead instrument `ParallelWorkerMain` /
  process exit directly.
- Optional database×role keying.
- Optional attribution of maintenance work (autovacuum) to table
  owners.

## License

Released under the [PostgreSQL License](LICENSE).

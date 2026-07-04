# pgstats reset & `pg_stat_kind_info` — execution-based verification

**Target:** PostgreSQL `master` @ `6d4ca6d` (== `origin/master`, 2026-07-03), which
contains the two commits under test:

- `3b066de` — *Add system view `pg_stat_kind_info`*
- `8c579bd` — *Add backend-level lock statistics*

Build: `./configure --enable-debug --enable-cassert --without-icu CFLAGS="-O0 -g3"`
(assertions ON). Every conclusion below is from a **running** server, not static
reading. Repro scripts are in `scripts/`.

> Note on the setup: the repo's *local* `master` ref was stale (`dbaa4dc`, 2026-06-27)
> and did **not** contain either commit. The real tip is `origin/master`/`6d4ca6d`;
> all testing was done there.

---

## TL;DR

| Area | Verdict |
|------|---------|
| `pg_stat_reset_shared(<target>)` selectivity | ✅ Correct — each target resets **only** its own view; `NULL` resets all shared kinds; per-object (relation/db/function) stats never touched |
| Invalid reset target | ✅ Clean `ERROR: unrecognized reset target`, case/space-sensitive, no crash |
| Reset-during-lock-wait race | ✅ No negative/overflow values (impossible by construction); benign positive re-add of in-flight pending (pre-existing design behavior) |
| `pg_stat_reset_backend_stats(pid)` | ✅ Backend copy zeroed, global preserved; and global `lock` reset preserves backend copy — clean bidirectional isolation |
| `entry_count` accuracy (opt-in custom kind) | ✅ Accurate; increments on create, decrements on drop, no leak over repeated cycles |
| `entry_count` for **built-in** kinds | ⚠️ **Always `NULL`** for all 13 built-in kinds (incl. `relation`/`database`/`function`) — see Finding F1 |
| Assertions / crashes | ✅ None (no TRAP/PANIC/core across the whole run) |

**No functional regression or crash was found in either commit.** The single
report-worthy item is a documentation-vs-behavior gap on `entry_count` (F1).

---

## Finding F1 (doc/usability): `entry_count` is `NULL` for *every* built-in kind

Observed baseline (`SELECT * FROM pg_stat_kind_info ORDER BY id`):

```
 id |     name     | builtin | fixed_amount | accessed_across_databases | write_to_file | entry_count
----+--------------+---------+--------------+---------------------------+---------------+-------------
  1 | database     | t       | f            | t                         | t             |   (NULL)
  2 | relation     | t       | f            | f                         | t             |   (NULL)
  3 | function     | t       | f            | f                         | t             |   (NULL)
  4 | replslot     | t       | f            | t                         | t             |   (NULL)
  5 | subscription | t       | f            | t                         | t             |   (NULL)
  6 | backend      | t       | f            | t                         | f             |   (NULL)
  7 | archiver     | t       | t            | f                         | t             |   (NULL)
  8 | bgwriter     | t       | t            | f                         | t             |   (NULL)
  9 | checkpointer | t       | t            | f                         | t             |   (NULL)
 10 | io           | t       | t            | f                         | t             |   (NULL)
 11 | lock         | t       | t            | f                         | t             |   (NULL)
 12 | slru         | t       | t            | f                         | t             |   (NULL)
 13 | wal          | t       | t            | f                         | t             |   (NULL)
```

`count(*) FILTER (WHERE entry_count IS NOT NULL)` = **0 of 13**.

Creating 100 tables (214 relations tracked in `pg_stat_all_tables`) and flushing
leaves `relation.entry_count` still `NULL`.

### Why (root cause, with execution proof)

`entry_count` is emitted only when a kind sets `track_entry_count`:

- `src/backend/utils/activity/pgstat_kind.c:62-65` — `if (info->track_entry_count) values[6] = …; else nulls[6] = true;`
- **No built-in kind sets it.** `track_entry_count` is assigned `= true` in exactly
  one place in the whole tree: `src/test/modules/test_custom_stats/test_custom_var_stats.c:112`.
  The built-in table `pgstat_kind_builtin_infos[]` (`pgstat.c:283-502`) never sets it.

Proof that the mechanism *does* work for an opt-in kind — loading
`test_custom_var_stats` (which sets `track_entry_count = true`):

```
entry_count before creating entries : 0
create 3 entries + flush            : 3      -- increments
drop 2 entries + flush              : 1      -- decrements
repeated create-20 / drop-20 x3     : peak 21 -> back to 1 each cycle  -- NO leak
```

### The doc gap

`doc/src/sgml/monitoring.sgml:3419` describes `entry_count` as:

> *"Number of tracked entries for this kind. For variable-numbered kinds, this is
> the number of objects currently tracked. NULL for fixed-sized statistics kinds,
> or if the kind does not track entry counts."*

The leading sentence ("For variable-numbered kinds, this is the number of objects
currently tracked") is true for **zero** built-in kinds — every built-in
variable-numbered kind (`database`, `relation`, `function`, `replslot`,
`subscription`, `backend`) reports `NULL`. A reader will reasonably expect
`relation.entry_count` to be the table count; it is always `NULL`. The trailing
caveat ("or if the kind does not track entry counts") technically covers it but is
easy to miss.

**This is by-design (only opt-in kinds populate the column), not a crash or data
bug** — but the column is uninformative for all shipped built-in stats, and the
docs oversell it. Actionable fix is either doc clarification or enabling
`track_entry_count` on the built-in variable kinds. Because the view did not exist
before `3b066de`, there is nothing to regress against.

Minimal repro: `SELECT name, builtin, fixed_amount, entry_count FROM pg_stat_kind_info WHERE builtin;`

---

## Reset selectivity matrix (observed, value-based)

Method (`scripts/matrix.sh`): fill all shared stats + generate a heavyweight-lock
wait, flush, snapshot every shared view's `stats_reset` + a representative counter,
run `pg_stat_reset_shared(<target>)`, snapshot again, diff.

Legend: `TS` = `stats_reset` updated? · `val` = representative counter before→after.
`.` = untouched, `RESET` = updated/zeroed by the target.

| reset target ↓ / view → | archiver | bgwriter | checkpointer | io | lock | slru | wal | recovery_prefetch |
|---|---|---|---|---|---|---|---|---|
| `io`                | . | . | . | **RESET** | . | . | . | . |
| `wal`               | . | . | . | . | . | . | **RESET** (80456→0) | . |
| `bgwriter`          | . | **RESET** | . | . | . | . | . | . |
| `checkpointer`      | . | . | **RESET** (1090→0) | . | . | . | . | . |
| `slru`              | . | . | . | . | . | **RESET** (4554→0) | . | . |
| `lock`              | . | . | . | . | **RESET** (7→0) | . | . | . |
| `archiver`          | **RESET** | . | . | . | . | . | . | . |
| `recovery_prefetch` | . | . | . | . | . | . | . | **RESET** |
| `NULL` (all)        | **RESET** | **RESET** | **RESET** (925→0) | **RESET** | **RESET** (3→0) | **RESET** (88→0) | **RESET** (127032→0) | **RESET** |

Every single-target reset updates **only its own** view's `stats_reset` and zeros
**only its own** counters. `NULL` resets all shared kinds. No collateral, no misses.

Caveat you may notice in raw output: `io`'s counter never reaches exactly 0 — the
monitoring query itself performs IO *after* the reset, so it re-accrues immediately
(e.g. `263196→69`). That is live activity, not a collateral/failed reset; `wal`,
`slru`, `checkpointer`, `lock` all reach exactly 0.

Per-object isolation (separate check): after `pg_stat_reset_shared('io')`,
`('wal')`, and `()`, `pg_stat_user_tables` scan counts and `pg_stat_database`
counters/`stats_reset` are unchanged (never zeroed). Shared resets never reach
per-relation/-database/-function stats.

Invalid targets (`lockk`, ``, `Lock`, `LOCK`, ` lock`, `xyz`) each raise
`ERROR: unrecognized reset target: "…"` (matching is a case- and whitespace-
sensitive `strcmp`; `pgstatfuncs.c:1986-1990`). No crash. `NULL` argument = reset-all.

---

## Reset-during-lock-wait race (negative-value hunt)

`scripts/race.sh`: session B blocks on an `ACCESS EXCLUSIVE` lock, counting a wait
into its **local** pending; a third session runs `pg_stat_reset_shared('lock')`
*before* B flushes; then B flushes.

Observed:

```
after reset (B still holds stale pending) : pg_stat_lock waits = (none)
after B flushes stale pending post-reset  : relation | waits=1 | wait_time≈1501ms
negative/overflow scan (waits<0 OR wait_time<0) : (empty) -> NONE
```

**No negatives, no overflow.** This is provable from the code: the only place lock
stats decrease is reset (`memset`, `pgstat_lock.c:102`); flush is purely additive
(`+=`, `pgstat_lock.c:71-73`); snapshot only copies. So a post-reset flush can only
*add positive* pending — never produce a negative.

The visible effect is that a reset can be partially "undone": in-flight pending
that predates the reset is added *after* it, so `pg_stat_lock` isn't perfectly zero
immediately post-reset. This is inherent to the pending/flush model of **all**
fixed-amount stats (io/wal/lock), long predates these commits, and is benign.

---

## Backend-level lock stats reset (commit 8c579bd)

`scripts/backend.sh`, single persistent subject backend B.

Direction 1 — `pg_stat_reset_backend_stats(pid)`:

```
[1] BEFORE : backend(B) relation waits=1 (1297.7ms) ; global relation waits=1 (1297.7ms)
[2] AFTER  : backend(B) relation waits=0 (0.0ms)    ; global relation waits=1 (1297.7ms)  <- global preserved
```

Direction 2 — `pg_stat_reset_shared('lock')`:

```
BEFORE : backend(B) relation waits=1
AFTER  : backend(B) relation waits=1  (SURVIVES) ; global = empty (0)
```

Backend (`PGSTAT_KIND_BACKEND`) and global (`PGSTAT_KIND_LOCK`) lock stats reset
**independently and correctly**. The new backend lock counters
(`pg_stat_get_backend_lock(pid)`) are properly scoped and cleared. No collateral.

---

## Environment / reproducibility

- Server runs as unprivileged user `claude`; binaries installed to
  `/usr/local/pgsql`, data dir `/home/claude/pgwork/pgdata`.
- Client tools require `LD_LIBRARY_PATH=/usr/local/pgsql/lib` (a system `libpq`
  shadows the built one otherwise).
- GUCs set: `track_functions=all`, `track_io_timing=on`, `track_wal_io_timing=on`,
  `autovacuum_naptime=5s`.
- Custom-stats demonstration requires
  `shared_preload_libraries='test_custom_var_stats'` + `CREATE EXTENSION`.

Scripts: `scripts/mon.sql` (snapshot), `scripts/fill.sql` (activity),
`scripts/genlock.sh` (lock wait), `scripts/matrix.sh` (selectivity matrix),
`scripts/race.sh` (race), `scripts/backend.sh` (backend reset).

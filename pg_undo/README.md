# pg_undo — Ctrl+Z for PostgreSQL

**Undo accidental DML with one SQL call.** pg_undo captures old/new row
images of tracked tables through logical decoding into an in-database
history, and can generate and apply the inverse operations.

> **Target version: PostgreSQL 19 (19devel / 19beta1) only.**
> The build fails on any other major version by design.

```sql
CREATE EXTENSION pg_undo;
SELECT undo.track('users');

-- ... disaster strikes ...
DELETE FROM users;              -- forgot the WHERE!

SELECT * FROM undo.recent_changes('users', '10 minutes');
SELECT * FROM undo.preview(last => '10 minutes', "table" => 'users');
SELECT * FROM undo.apply(last => '10 minutes', "table" => 'users');
--  applied | skipped | conflicts
-- ---------+---------+-----------
--    48213 |       0 |         0
```

## How it works

A background worker (started via `shared_preload_libraries`) consumes a
logical replication slot **in-process** — no walsender, no network. The
bundled output plugin buffers old/new row images of committed
transactions in memory; the worker then writes them to `undo.history` in
its own transaction and only afterwards confirms the slot, so a crash
never loses or duplicates history (progress-LSN dedupe).

- `undo.track(t)` sets `REPLICA IDENTITY FULL` so UPDATE/DELETE carry
  complete old rows. Unchanged TOAST values are merged in at capture
  time; images in `undo.history` are always complete.
- `undo.preview(...)` / `undo.apply(...)` generate inverse DML
  (`DELETE`→`INSERT`, `UPDATE`→reverse `UPDATE`, `INSERT`→`DELETE`),
  newest change first, with per-row conflict detection
  (`on_conflict => 'abort' | 'skip' | 'force'`).
- A janitor enforces `pg_undo.retention` and a failsafe: if
  `undo.history` exceeds `pg_undo.max_history_size`, capture pauses
  (with a WARNING) but the slot keeps advancing so WAL never piles up.
  It resumes automatically once space is reclaimed.

## Installation

```sh
make PG_CONFIG=/path/to/pg19/bin/pg_config install
```

postgresql.conf:

```
shared_preload_libraries = 'pg_undo'
wal_level = logical
pg_undo.database = 'yourdb'     # database to capture in
```

Restart, then `CREATE EXTENSION pg_undo;` in that database.

## Configuration

| GUC | Default | Meaning |
|---|---|---|
| `pg_undo.database` | `postgres` | Database the worker connects to |
| `pg_undo.enabled` | `on` | Master switch (SIGHUP) |
| `pg_undo.naptime` | `1s` | Capture cycle interval |
| `pg_undo.retention` | `24 hours` | How long history is kept |
| `pg_undo.max_history_size` | `10240` (MB) | Failsafe pause threshold |
| `pg_undo.janitor_interval` | `60s` | GC / failsafe check interval |

## SQL API

| Function | Description |
|---|---|
| `undo.track(regclass)` / `undo.untrack(regclass)` | Start/stop capturing a table |
| `undo.recent_changes(regclass, interval)` | Who changed what, with row images |
| `undo.preview(xid, last, since, until, "table")` | Show inverse SQL without executing |
| `undo.apply(..., on_conflict)` | Execute the inverse operations in one transaction |
| `undo.status` (view) | Capture progress, slot position, pause state |

## Honest limitations (v0.1)

- One database per cluster (`pg_undo.database`).
- `REPLICA IDENTITY FULL` increases WAL volume for UPDATE/DELETE on
  tracked tables (old rows are logged in full).
- History lives in the same database and consumes disk in proportion to
  write volume × retention. This is **not a backup**: it protects
  against logical mistakes, not media failure.
- `changed_by` is NULL: WAL does not record the acting role.
- `TRUNCATE` is recorded but cannot be undone; DDL is out of scope
  (a recycle bin for `DROP TABLE` is on the roadmap).
- Undoing a very large transaction buffers it in worker memory.
- `undo` schema objects are superuser-only by default.

## Tests

```sh
make PG_CONFIG=... check       # pg_regress (spins up a temp instance)
make PG_CONFIG=... prove_installcheck   # TAP (restart survival etc.)
```

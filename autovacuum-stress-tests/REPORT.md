# Autovacuum boundary / stress test report — PostgreSQL master (20devel)

**Conclusion: no anomalies found.** All four scenarios (X1–X4) behaved exactly
as specified. Every judgment below is backed by observed evidence (server logs,
`pg_stat_progress_vacuum`, `/proc/<pid>/status`), not static code reading.

## Environment

| item | value |
|------|-------|
| Source | PostgreSQL master, `postgres (PostgreSQL) 20devel` |
| Build | `./configure --enable-debug --enable-cassert CFLAGS="-O0 -g3"` |
| Host | Ubuntu 24.04, 4 vCPU, 15 GiB RAM |
| Key GUCs | `autovacuum_naptime=1s`, `autovacuum_work_mem=1MB`, `autovacuum_vacuum_cost_delay=0`, `log_autovacuum_min_duration=0` |

The server runs as OS user `postgres` (PostgreSQL refuses to run as root), data
directory `/home/user/pgav-data5`. `autovacuum_work_mem` was verified in effect
as `1024 kB` before any test.

---

## X1 — Multiple index-vacuum passes under a tiny 1 MB TidStore

**Setup:** `mp(a int, b text)`, 5,000,000 rows, indexes `mp_a`, `mp_b`, then
`DELETE WHERE a%2=0` → 2,500,000 dead tuples ≫ 1 MB.

**Observed** (`logs/x1-vacuum-mp.log`, authoritative autovacuum log line):

```
automatic vacuum of table "postgres.public.mp": index scans: 3
  index scan needed: 41667 pages ... had 2500000 dead item identifiers removed
  index "mp_a": pages: 13713 ...
  index "mp_b": pages: 36045 ...
  memory usage: dead item storage 2.83 MB accumulated across 3 resets (limit 1.00 MB each)
  system usage: ... elapsed: 9.47 s
```

`pg_stat_progress_vacuum` was sampled mid-run (`logs/x1-progress-monitor.log`)
and caught `index_vacuum_count=2`, `max_dead_tuple_bytes=1048576` (=1 MB,
matching `autovacuum_work_mem`), `dead_tuple_bytes=720896`.

**Verdict: PASS.** `index_vacuum_count` reached **3** (≥ 2 required). The log's
`index scans: 3` is consistent with the progress counter, and
`memory usage: dead item storage 2.83 MB accumulated across 3 resets (limit
1.00 MB each)` proves the 1 MB TidStore limit forced the multi-pass behavior —
i.e. the memory cap is effective, not bypassed. No hang.

> Note: the machine is fast enough that the 2.5 M-tuple vacuum completed in
> 9.47 s, so the 5 s poller only captured one in-progress sample. The
> authoritative evidence is the completion log line, which cannot be raced.

---

## X2 — Self-cancellation on lock conflict

**Setup:** `cx(a,b)`, 3,000,000 rows, `DELETE WHERE a%2=0`. Regular autovacuum
of `cx` at `cost_delay=0` completes in ~2 s — too fast to race on this host. To
open a deterministic observation window, `cx` alone was throttled via
per-table storage params (`autovacuum_vacuum_cost_delay=20`,
`autovacuum_vacuum_cost_limit=100`); the global setting stayed at 0. Fresh dead
tuples were then generated to trigger a slow (throttled) autovacuum.

**Observed** (`logs/x2-cancel.log`): worker was caught mid heap-scan, then an
`ACCESS EXCLUSIVE` `LOCK TABLE cx` was issued:

```
[worker 21870] ERROR:  canceling autovacuum task
[worker 21870] CONTEXT:  while scanning block 221 of relation "public.cx"
                         automatic vacuum of table "postgres.public.cx"
[client 21880] STATEMENT: LOCK TABLE cx IN ACCESS EXCLUSIVE MODE; SELECT 1 ...
```

`LOCK TABLE ... ACCESS EXCLUSIVE` returned in **1.003 s** (`got_lock=1`,
`rc=0`), well under the 60 s timeout.

**Verdict: PASS.** The autovacuum yielded promptly. The ~1 s latency equals the
default `deadlock_timeout` — the lock waiter signals the blocking autovacuum
after `deadlock_timeout`, which then cancels itself. Exactly the documented
behavior.

---

## X3 — Crash-recovery crossings

### X3a — SIGKILL an autovacuum worker mid-vacuum

Worker 21888 was `kill -9`'d while `scanning heap 13633/25000`.

**Observed** (`logs/x3a-sigkill-recovery.log`):

```
postmaster: autovacuum worker (PID 21888) was terminated by signal 9: Killed
             Failed process was running: autovacuum: VACUUM ANALYZE public.cx
             all server processes terminated; reinitializing
recovery:    database system was not properly shut down; automatic recovery in progress
             redo starts at 0/6410B600
             redo done at 0/9D613F18 ... elapsed: 13.17 s
             checkpoint starting: end-of-recovery
             database system is ready to accept connections
```

- (1) Recovery completed normally. ✔
- (2) `cx` was re-vacuumed after recovery and completed cleanly (once fresh DML
  updated its stats — see note below). ✔
- (3) No `PANIC` / `TRAP` / assertion. ✔

> **Expected nuance (not a bug):** the cumulative statistics views are *not*
> crash-safe. After the SIGKILL-induced crash, `pg_stat_user_tables` for `cx`
> showed `n_dead_tup=0, autovacuum_count=0` even though ~375k dead tuples were
> still physically present. Consequently autovacuum did not immediately
> reschedule `cx` on dead-tuple pressure; it did so as soon as new DML updated
> the counters (then completed in ~4 s). This matches PostgreSQL's documented
> design — dead-tuple driven scheduling restarts from zero after a crash, while
> anti-wraparound scheduling (driven by crash-safe `pg_class.relfrozenxid`)
> would still fire regardless.

### X3b — `pg_ctl -m immediate stop` mid-vacuum, then restart

Immediate shutdown issued while a throttled `cx` vacuum was `scanning heap
25/25000`.

**Observed** (`logs/x3b-immediate-recovery.log`):

```
database system was not properly shut down; automatic recovery in progress
redo starts at 0/9D6140C8
redo done at 0/A8CC8F78 ... elapsed: 2.06 s
checkpoint complete: end-of-recovery ...
database system is ready to accept connections
```

**Verdict (both crossings): PASS.** No `PANIC`/`TRAP`.

> The `unexpected pageaddr ...` / `invalid record length ...` lines seen just
> before `redo done` are **LOG-level**, not errors: they are the normal way
> redo detects the end of the valid WAL stream. They are always immediately
> followed by `redo done`.

A later abrupt kill of the whole server (container suspend during X4) provided
a third, independent crash-recovery crossing: it too recovered cleanly
(`redo done`, 22.71 s), and a data-integrity check afterward confirmed
`pgbench_accounts` = 5,000,000 rows and the TPC-B invariant
`sum(abalance) = sum(bbalance)` holds → no corruption.

---

## X4 — 30-minute churn and launcher leak monitoring

**Setup:** `pgbench -i -s 50` (5 M-row `pgbench_accounts`), then
`pgbench -T 1800 -c 8 -j 4`. Launcher and worker `VmRSS` sampled from
`/proc/<pid>/status` every 10 s.

**pgbench result** (`logs/x4-pgbench.out`):

```
duration: 1800 s
number of transactions actually processed: 3849139
number of failed transactions: 0 (0.000%)
tps = 2138.406387
PGBENCH_EXIT=0
```

**Errors / autovacuum activity** (`logs/x4-autovac-and-errors.log`):

- `PANIC` / `TRAP` / `Assert`: **0**
- real `ERROR` / `FATAL` (excluding autovacuum-cancel noise): **0**
- autovacuum runs during churn: `pgbench_tellers` ×1745, `pgbench_branches`
  ×1711, `pgbench_history` ×34 — autovacuum ran continuously (the small hot
  TPC-B tables are vacuumed at the `naptime=1s` cadence).

**Launcher VmRSS time series** (`logs/x4-rss.log`, downsampled in
`logs/x4-rss-downsampled.tsv`, 198 samples over ~33 min):

```
t+0s     9572 kB   (baseline)
t+110s   9636 kB
t+230s   9652 kB
t+590s   9656 kB
...
t+1977s  9656 kB   (plateau, unchanged for the final ~23 min)
```

Total growth: **9572 → 9656 kB = +84 kB (+0.9%)**, and the value **plateaus**
after ~10 minutes. The leak criterion (+50 % and still rising) is nowhere near
met.

**Verdict: PASS.** pgbench exit 0 with zero failed transactions; no
ERROR/TRAP/PANIC; autovacuum ran throughout; launcher RSS flat → no leak.

---

## Summary

| Test | Criterion | Result |
|------|-----------|--------|
| X1 | `index_vacuum_count ≥ 2`, memory cap effective | ✅ 3 passes, "2.83 MB across 3 resets (limit 1.00 MB)" |
| X2 | LOCK acquired quickly + `canceling autovacuum task` | ✅ 1.003 s, cancellation logged |
| X3a | SIGKILL → clean recovery, no PANIC/TRAP | ✅ redo done 13.17 s, reschedules, no PANIC |
| X3b | immediate stop → clean recovery, no PANIC/TRAP | ✅ redo done 2.06 s, no PANIC |
| X4 | pgbench rc0, no ERROR/TRAP, AV runs, no launcher leak | ✅ rc0/0 failed, AV ×3490, RSS +0.9% flat |

No `repro.sh` for a defect is required because no anomaly was found; a
self-contained `scripts/repro.sh` is nonetheless provided so the whole battery
can be re-run from `initdb`.

# Autovacuum XID-wraparound — empirical verification (PostgreSQL master)

Hands-on verification that master's autovacuum wraparound protection behaves correctly,
driven by **real XID consumption** via the in-tree `xid_wraparound` test module. No
conclusions are drawn from static reading — every verdict is backed by server logs,
`pg_stat_progress_vacuum`, and `/proc` observations.

## Environment
- **PostgreSQL 20devel (master)**, built `--enable-debug --enable-cassert CFLAGS="-O0 -g3"`.
- Extensions: `xid_wraparound` (`consume_xids`), `pg_visibility`.
- Two clusters: W-series (`autovacuum_freeze_max_age=200000`, freeze mins 0) and
  X-series (`autovacuum_work_mem=1MB`). `autovacuum_naptime=1s`, `log_autovacuum_min_duration=0`.

## Results — all PASS, zero TRAP/PANIC

| # | What is verified | Verdict | Evidence |
|---|---|---|---|
| W1 | Anti-wraparound vacuum forced even on `autovacuum_enabled=off` | ✅ | `…to prevent wraparound of table "…frozen_target"`; age→0 |
| W2 | Failsafe engages past `vacuum_failsafe_age` | ✅ | `bypassing nonessential maintenance of table "…fs" as a failsafe` |
| W3 | Wraparound vacuum is **not** self-cancelled by a conflicting lock | ✅ | LOCK blocked 6.73s until vacuum completed; 0 cancels |
| W4 | Autovacuum catches up after a large age jump | ✅ | peak age 10,000,003 → 0 in 2s |
| X1 | 1MB TidStore forces multi-pass index vacuum | ✅ | `index_vacuum_count` 0→1→2→3, `index scans: 3` |
| X2 | A **normal** vacuum self-cancels on lock conflict | ✅ | `canceling autovacuum task … index "cx_b"`, granted in 1.01s |
| X3 | Crash recovery (SIGKILL worker + immediate shutdown) | ✅ | clean redo, table integrity intact, 0 TRAP/PANIC |
| X4 | 15-min churn: no worker/launcher leak | ✅ | launcher RSS +0.75% over 15 min; 1753 autovacuums; 0 failed txns |

W3 vs X2 is the crisp behavioral contrast: the wraparound vacuum makes the lock **wait**
(6.73s, until it finishes) while the ordinary vacuum **yields** the lock (~1s = deadlock_timeout).

## The one notable finding (a test-recipe gap, not a Postgres defect)

Running W1 exactly as specified, `age(datfrozenxid)` sat **stuck at 300000 for 300s** — which
superficially looks like a severe "datfrozenxid won't advance" failure. Root cause:

`consume_xids()` burns XIDs via `consume_xids_shortcut()`, which bumps
`TransamVariables->nextXid` **directly, without assigning or committing** those XIDs. Only the
consume transaction's own top XID (~711) actually commits, so `latestCompletedXid` — and thus
`OldestXmin`/the freeze cutoff — stays pinned near 711 while `nextXid` is ~300700. The forced
aggressive anti-wraparound vacuum *does* run (logs prove it) but legitimately cannot freeze past
`OldestXmin`, emitting `WARNING: cutoff for removing and freezing tuples is far in the past`.

**Fix:** run one real committed write afterward to advance `latestCompletedXid`. This is exactly
what upstream `src/test/modules/xid_wraparound/t/001_emergency_vacuum.pl` does
(`INSERT INTO small(data) SELECT 1` — *"Make sure the latest completed XID is advanced"*). With
that single `INSERT`, the horizon jumped to 300712 and `age` fell to 0 within 3s. `repro.sh`
here bakes in that step at every stage.

## Files
- `repro.sh` — self-contained reproduction (set `DO_BUILD=1` to build from scratch; `DO_X4=1`
  for the long churn test). Runs W1–W4 and X1–X3, prints the pass/fail evidence for each.
- `RESULTS.md` — full per-check narrative with timings and log lines.
- `log-evidence.txt` — selected raw server-log lines cited above.
- `x4-launcher-rss.log` — launcher `VmRSS` time series from the 15-min churn.

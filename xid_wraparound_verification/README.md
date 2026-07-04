# XID-wraparound autovacuum verification (PostgreSQL master)

Empirical verification that master's autovacuum XID-wraparound protections work,
by actually burning XIDs with the `xid_wraparound` test module's `consume_xids()`
(not static reading). Built with `--enable-cassert` so freeze / visibility-map
consistency assertions surface as `TRAP`.

## Result: W1 PASS · W2 PASS · W3 PASS · W4 PASS — no anomaly. See `RESULTS.md`.

| Scenario | What it checks | Evidence |
|---|---|---|
| **W1** | anti-wraparound vacuum is forced even on `autovacuum_enabled=off` tables, and `datfrozenxid` advances | `to prevent wraparound` on `frozen_target`; max age 300000 → 0 |
| **W2** | failsafe kicks in and skips index vacuuming | `bypassing nonessential maintenance of table "postgres.public.fs" as a failsafe`; `index scans: 0`, 1,000,000 dead item ids left |
| **W3** | a for-wraparound vacuum is **not** self-cancelled by a conflicting lock | `ACCESS EXCLUSIVE` lock waited 46s until the vacuum finished; 0 `canceling autovacuum task` |
| **W4** | age recovers (not stuck/monotonic) at high age | big2 age 10,000,027 → 0 with 3,000,000 tuples frozen |

## Key gotcha discovered
`consume_xids()` bumps `nextXid` via a shortcut but does **not** advance
`latestCompletedXid`. On an idle cluster the xmin horizon stays pinned at its
pre-consume value, so VACUUM can't lower `relfrozenxid` and age looks "stuck"
even though anti-wraparound vacuum is firing. One real committed transaction
unpins it (observed: horizon 711 → 300712 → age 0). A production DB never
stalls because ongoing activity keeps the horizon advancing. `repro.sh` runs a
background "xid ticker" to emulate that.

## Files
- `RESULTS.md` — full findings, age(datfrozenxid) time series, exact log lines.
- `repro.sh` — self-contained end-to-end reproduction (build → init → W1-W4 → invariants).
- `w1.sh`–`w4b.sh`, `ticker.sh` — the individual scripts used during the run.

Run: `PREFIX=$HOME/pgav DATA=$HOME/pgav-data4 SRC=$HOME/pgsrc bash repro.sh` (as a non-root user).

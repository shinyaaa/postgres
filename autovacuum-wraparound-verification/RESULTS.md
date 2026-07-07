# Autovacuum XID-wraparound verification — results

Build: PostgreSQL 20devel (master), `--enable-cassert --enable-debug -O0 -g3`.
Modules: xid_wraparound, pg_visibility. Cluster: pgav-data4 (W-series).
Config: autovacuum_naptime=1s, autovacuum_freeze_max_age=200000, vacuum_freeze_min_age=0,
vacuum_freeze_table_age=0, log_autovacuum_min_duration=0.

## Global crash check
No TRAP/PANIC/signal in any log across the whole W-series run. (cassert build.)

## W1 — forced anti-wraparound vacuum (incl. autovacuum_enabled=off) — PASS (with key finding)

Timeline:
- baseline age(datfrozenxid) = 24
- consume_xids(300000) → age = 300025 (> freeze_max_age 200000)
- 300s monitor: age STUCK at 300000; did NOT drop.
- Logs: thousands of `automatic aggressive vacuum to prevent wraparound` on catalogs,
  toast tables, AND `postgres.public.frozen_target` (autovacuum_enabled=off) — so the
  forced anti-wraparound vacuum DID fire, including on the autovacuum-disabled table.
- Alongside every vacuum: `WARNING: cutoff for removing and freezing tuples is far in the
  past` (8222 occurrences in first log alone).

Root cause of the stuck age (NOT a Postgres bug):
- `consume_xids()` burns XIDs via `consume_xids_shortcut()` which bumps
  `TransamVariables->nextXid` directly WITHOUT assigning/committing those XIDs. Only the
  consume transaction's own top XID (~711) actually commits.
- So `latestCompletedXid` (and thus OldestXmin / the vacuum freeze cutoff) stayed pinned
  near 711 while nextXid was ~300700. Vacuum ran but could not freeze past OldestXmin, so
  relfrozenxid/datfrozenxid could not advance — hence the WARNING and the stuck age.
- The official TAP test src/test/modules/xid_wraparound/t/001_emergency_vacuum.pl line 73-74
  handles exactly this: after consume_xids it does `INSERT INTO small(data) SELECT 1`
  ("Make sure the latest completed XID is advanced"). The W1 procedure omitted that step.

Empirical proof:
- Before write: pg_current_snapshot xmin = 711, max age = 300000 (stuck for 300s).
- One committed `INSERT` → snapshot xmin jumped to 300712.
- Within 3 seconds autovacuum advanced datfrozenxid → max age = 0. ADVANCED.
- frozen_target (autovacuum_enabled=off): final age 0, autovacuum_count=1348, last_autovacuum succeeded.

Verdict: anti-wraparound aggressive vacuum is forced even on autovacuum_enabled=off tables,
and datfrozenxid advances to 0 once the xmin horizon is allowed to move. Behavior correct.

## W2 — failsafe firing — PASS
- vacuum_failsafe_age=300000. fs(2M rows)+index, deleted 1M. consume_xids(400000) → fs age 400003.
- After advancing latest xid, autovacuum ran anti-wraparound vacuum on fs; failsafe tripped.
- Log: `WARNING: bypassing nonessential maintenance of table "postgres.public.fs" as a failsafe
  after 0 index scans` / DETAIL `The table's relfrozenxid or relminmxid is too far in the past.`
  fs failsafe DETAIL: 16667 pages (100%) with 1000000 dead item identifiers, index scan bypassed.
- 463 total failsafe bypass events across catalogs/toast/fs. fs age → 0 afterward.

## W3 — anti-wraparound vacuum not self-cancelled by lock conflict — PASS
- aw(5M rows, autovacuum_enabled=off)+index, deleted 2.5M (dead tuples persist). consume_xids(300000)+INSERT.
  aw age=300006 → forced "to prevent wraparound" vacuum runs with full index scan (slow).
- Raced `LOCK TABLE aw IN ACCESS EXCLUSIVE MODE` (lock_timeout 30s) while vacuum in progress
  (phase=scanning heap).
- Result: LOCK BLOCKED 6.73s (wall clock) until the wraparound vacuum COMPLETED
  (log: `automatic aggressive vacuum to prevent wraparound of table "postgres.public.aw":
  index scans: 1` at 23:08:46.323), then was granted 20ms later.
- `canceling autovacuum task`: 0 occurrences in the entire cluster log.
- Verdict: wraparound vacuum is NOT self-cancelled by a conflicting lock; requester waits. Correct.

## W4 — wraparound catch-up health — PASS
- consume_xids(10,000,000) + advance latest xid → peak max(age(datfrozenxid)) = 10,000,003.
- Autovacuum caught up: all databases (postgres/template0/template1) age → 0 within 2s.
- No monotonic increase / no fixation.

## Global crash check (W cluster) — CLEAN
- TRAP/PANIC/signal across all W-cluster logs: 0 (grep count)

# ============ P5 X-series (cluster pgav-data5, autovacuum_work_mem=1MB) ============

## X1 — low-memory multi-pass index vacuum (TidStore) — PASS
- mp(5M rows)+2 indexes(mp_a,mp_b), deleted 2.5M → dead tuples ≫ 1MB TidStore.
- Live pg_stat_progress_vacuum: max_dead_tuple_bytes=1048576 (=1MB autovacuum_work_mem exactly);
  dead_tuple_bytes fills past ~1.06MB then flushes; index_vacuum_count progressed 0→1→2→(3).
- Log: `automatic vacuum of table "postgres.public.mp": index scans: 3`.
- Verdict: 2.5M dead TIDs cannot be held in 1MB, so index vacuum ran in 3 passes. Correct.

## X2 — normal vacuum self-cancels on lock conflict — PASS
- cx(3M rows)+index, deleted 1.5M → normal autovacuum runs (age small, NOT wraparound).
- Raced `LOCK TABLE cx IN ACCESS EXCLUSIVE MODE` while vacuum in progress (scanning heap).
- LOCK granted in 1.01s (≈ deadlock_timeout 1s). Log: `ERROR: canceling autovacuum task`
  CONTEXT `while vacuuming index "cx_b" of relation "public.cx"`.
- Contrast with W3: wraparound vacuum did NOT cancel (lock waited 6.73s); normal vacuum cancels. Correct.

## X3 — crash recovery crossing — PASS
- bx(4M)+index, 1M fresh dead tuples. Caught autovacuum worker (pid 10120, phase scanning heap)
  and SIGKILL'd it.
- Postmaster: `autovacuum worker (PID 10120) was terminated by signal 9: Killed` /
  `terminating any other active server processes` / `all server processes terminated; reinitializing`
  / `automatic recovery in progress` / `redo starts` ... `redo done` / end-of-recovery checkpoint /
  `database system is ready to accept connections`. Recovery completed, 0 TRAP/PANIC.
- Post-recovery table integrity intact: count(bx)=1,000,000 (=4M-2M-1M). Residual dead tuples
  correctly removable by manual VACUUM (index scans: 1, 905500 removed). NB: autovacuum did not
  auto-retrigger because pgstat counters reset on crash (n_dead_tup=0) — expected, not a defect.
- immediate shutdown crossing: `pg_ctl -m immediate stop` + restart → crash recovery again
  completed cleanly (redo done, ready to accept connections), 0 TRAP/PANIC across all X logs.

## X4 — 15-min churn + launcher leak watch — PASS
- pgbench -i -s 50, then pgbench -T 900 -c 8 -j 4: rc=0, 1,965,072 txns, 0 failed, tps=2183.
- Autovacuum active throughout: sum(autovacuum_count) 1 → 1754 (1753 autovacuums).
- Launcher VmRSS (90 samples over 15 min): min 9592 kB, max 9664 kB, growth 72 kB (+0.75%).
  Flat — NO leak (far below the +50% concern threshold).
- Server log during X4: no unexpected ERROR/FATAL, 0 TRAP/PANIC. (The only FATAL in the whole
  X-cluster log is the initial port-5432-in-use start attempt; the only ERROR is the expected
  X2 `canceling autovacuum task`.)

# ============ OVERALL ============
W1 PASS, W2 PASS, W3 PASS, W4 PASS, X1 PASS, X2 PASS, X3 PASS, X4 PASS.
Zero TRAP/PANIC/segfault across both clusters (cassert build). No frozen/VM-integrity asserts.
Single notable finding: the naive W1 recipe omits the "advance latestCompletedXid" step that
consume_xids requires (upstream 001_emergency_vacuum.pl includes it); with it, all behavior is
correct. No PostgreSQL defect found.

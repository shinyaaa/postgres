# XID Wraparound Autovacuum Verification — PostgreSQL 20devel (master, cassert)

Commit: 6d4ca6d (master). Build: --enable-cassert --enable-debug -O0 -g3.
Config: autovacuum_freeze_max_age=200000, vacuum_freeze_min_age=0,
vacuum_freeze_table_age=0, autovacuum_naptime=1s, log_autovacuum_min_duration=0.

## W1: anti-wraparound vacuum forced firing — PASS
- ages before consume: 24; after consume_xids(300000): postgres db age=300025.
- "automatic aggressive vacuum to prevent wraparound" fired repeatedly (36428 lines).
- frozen_target (autovacuum_enabled=off) received 313 prevent-wraparound vacuums -> forced firing on a table with autovacuum disabled CONFIRMED.
- datfrozenxid advanced: max(age) 300000 -> 0 (fully frozen). frozen_target relfrozenxid age -> 0.
- TRAP/PANIC/signal count = 0. No core files.

### Important mechanism observed (not a bug)
For ~116s the vacuum logged continuously but age stayed at 300000. Root cause:
consume_xids() bumps nextXid via a shortcut but does NOT advance latestCompletedXid,
so on an otherwise idle cluster the xmin horizon (=latestCompletedXid+1) stayed pinned
at 711 (its pre-consume value). VACUUM cannot freeze XIDs newer than the oldest xmin,
so relfrozenxid/datfrozenxid could not advance. Proof:
  pg_snapshot_xmin(pg_current_snapshot()) = 711  (before any real xact)
  after one SELECT txid_current() (a real committed xact) -> xmin = 300712
  next autovacuum cycle: age -> 0 immediately.
In production this never stalls because ongoing transaction activity continuously
advances latestCompletedXid. For W2-W4 a background "xid ticker" emulates this.

## W2: failsafe firing — PASS
- vacuum_failsafe_age set to 300000. fs = 2M rows, index on b, 1M rows DELETEd (dead).
- fs relfrozenxid age: 10 (before consume) -> 400011 (after consume_xids(400000)) > 300000.
- FAILSAFE detected 2s into monitoring. Log evidence for the target table:
    WARNING: bypassing nonessential maintenance of table "postgres.public.fs" as a failsafe after 0 index scans
    LOG: automatic aggressive vacuum to prevent wraparound of table "postgres.public.fs": index scans: 0
    index scan bypassed by failsafe: 16667 pages from table (100.00% of total) have 1000000 dead item identifiers
- Before/after contrast: an earlier vacuum (failsafe_age still 1.6B) did "index scans: 1" (normal);
  after lowering failsafe_age + consume, vacuum did "index scans: 0" (index cleanup skipped).
- 461 "as a failsafe" bypass lines across the DB. TRAP/PANIC = 0.

## W3: anti-wraparound vacuum not self-cancelled on lock conflict — PASS
- aw = 5M rows, index on b, 1.67M deleted; reloptions throttle (cost_delay=10, cost_limit=300)
  to widen the in-progress window. vacuum_failsafe_age reset to 1.6B (full vacuum, no bypass).
- aw relfrozenxid age: 16 -> 400017 after consume_xids(400000); anti-wraparound vacuum started.
- Caught in pg_stat_progress_vacuum: pid 1510, query "autovacuum: VACUUM public.aw (to prevent
  wraparound)", phase "vacuuming indexes".
- NOTE: the first LOCK attempt used a bare `psql -c "LOCK ..."` which errors
  ("LOCK TABLE can only be used in transaction blocks") -> retried inside BEGIN/COMMIT.
- Valid attempt: ACCESS EXCLUSIVE lock requested 23:06:56.999, ACQUIRED 23:07:42.970 -> waited 46s.
- aw vacuum COMPLETION log: 23:07:42.970 [1510] "automatic aggressive vacuum to prevent wraparound
  of table postgres.public.aw: index scans: 1". Completion timestamp == lock-acquired timestamp:
  the lock was granted the instant the vacuum released, i.e. it WAITED for the vacuum to finish.
- "canceling autovacuum task": 0 lines anywhere. TRAP/PANIC = 0.
- Source corroboration (master): proc.c:1543-44 sends the cancel SIGINT only when
  (PROC_IS_AUTOVACUUM && !PROC_VACUUM_FOR_WRAPAROUND); vacuum.c:2060-61 sets
  PROC_VACUUM_FOR_WRAPAROUND when params.is_wraparound.

## W4: wraparound-warning soundness / age recovery — PASS
Two runs (vacuum_failsafe_age left at 1.6B):
(a) Pre-frozen tables: consume_xids(10,000,000) -> PEAK max(age(datfrozenxid))=10,000,377;
    recovered to 1 within ~2s. Fast because all pages were already all-frozen; the aggressive
    wraparound vacuum VM-skipped them (aw: 1/41667 pages scanned, 0 tuples frozen) and just
    advanced relfrozenxid. Not a stall -> valid.
(b) Fresh unfrozen data (stronger): big2 = 3,000,000 rows single-xmin, throttled reloptions.
    consume_xids(10,000,000) -> PEAK big2 age=10,000,027, maxdb age=10,000,209.
    Time series (big2_age / maxdb_age):
      1s 10000027/10000209 ... 6s 10000037/10000037 ; 7s 10000012/... ; 8s 0/14  -> RECOVERED at 8s.
    Freeze log: "automatic aggressive vacuum to prevent wraparound of table postgres.public.big2:
    index scans: 0 / pages: 25000 scanned (100%) / frozen: 25000 pages (100.00%) had 3000000 tuples
    frozen". Real freezing of all 3M tuples -> genuine catch-up, age NOT monotonic/stuck.
- TRAP/PANIC = 0.

## Always-on invariant
- Total TRAP:/PANIC/"terminated by signal" across all 8 log files = 0 (cassert build).
- No core files produced. 71 MB of logs total (dominated by W1's idle-window retry spam).

## pg_visibility integrity (cassert build, primary goal) — CLEAN
- pg_check_frozen / pg_check_visible on aw, big2, fs, frozen_target: all 0 rows
  (nothing marked all-frozen/all-visible in the VM that contradicts heap state).
- pg_visibility_map_summary: aw 41667/41667 all-frozen; big2 25000/25000 all-frozen.
- Global: TRAP=0, PANIC=0, FATAL=0. The only 2 ERRORs in the logs are self-inflicted test
  mistakes (bad function signature; ALTER SYSTEM inside a txn block), not server faults.

## OVERALL: W1 PASS, W2 PASS, W3 PASS, W4 PASS. No wraparound/freeze anomaly on master.

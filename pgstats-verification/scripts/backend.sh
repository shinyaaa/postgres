#!/bin/bash
source /home/claude/pgwork/env.sh
# Clean slate
$PSQL -q -c "SELECT pg_stat_reset_shared('lock'); SELECT pg_stat_force_next_flush();" >/dev/null 2>&1

# Session A holds ACCESS EXCLUSIVE for 2s (window t=0.5..2.5)
$PSQL -q -c "BEGIN; LOCK TABLE fill_t IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 &
sleep 0.2

# Subject session B: one backend, one pid, runs the whole scenario.
$PSQL -tAF'|' <<'SQL'
SELECT pg_sleep(0.5);
\echo '### B pid:'
SELECT pg_backend_pid();
-- block on A's lock, counting a heavyweight-lock wait into B's stats
SELECT count(*) FROM fill_t;
SELECT pg_stat_force_next_flush();
\echo '### [1] BEFORE any reset -- backend(B) lock vs global lock'
SELECT 'backend' src, locktype, waits, round(wait_time::numeric,1) wt FROM pg_stat_get_backend_lock(pg_backend_pid()) WHERE waits<>0
UNION ALL
SELECT 'global', locktype, waits, round(wait_time::numeric,1) FROM pg_stat_lock WHERE waits<>0;
\echo '### reset ONLY backend stats of B'
SELECT pg_stat_reset_backend_stats(pg_backend_pid());
SELECT pg_stat_force_next_flush();
\echo '### [2] AFTER pg_stat_reset_backend_stats -- expect backend=0, global preserved'
SELECT 'backend' src, locktype, waits, round(wait_time::numeric,1) wt FROM pg_stat_get_backend_lock(pg_backend_pid()) WHERE waits<>0
UNION ALL
SELECT 'global', locktype, waits, round(wait_time::numeric,1) FROM pg_stat_lock WHERE waits<>0;
\echo '### backend rows (all, incl zero) to confirm zeroing:'
SELECT locktype, waits, round(wait_time::numeric,1) wt, fastpath_exceeded FROM pg_stat_get_backend_lock(pg_backend_pid()) WHERE locktype='relation';
SQL
wait
echo "=== reverse direction: global reset must not zero a backend copy ==="
# New wait, then reset GLOBAL only, check backend copy survives
$PSQL -q -c "SELECT pg_stat_reset_shared('lock'); SELECT pg_stat_force_next_flush();" >/dev/null 2>&1
$PSQL -q -c "BEGIN; LOCK TABLE fill_t IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 &
sleep 0.2
$PSQL -tAF'|' <<'SQL'
SELECT pg_sleep(0.5);
SELECT count(*) FROM fill_t;
SELECT pg_stat_force_next_flush();
\echo '### backend(B) waits before global reset:'
SELECT locktype, waits FROM pg_stat_get_backend_lock(pg_backend_pid()) WHERE waits<>0;
SELECT pg_stat_reset_shared('lock');
SELECT pg_stat_force_next_flush();
\echo '### AFTER global lock reset -- backend copy should SURVIVE:'
SELECT 'backend' src, locktype, waits FROM pg_stat_get_backend_lock(pg_backend_pid()) WHERE waits<>0
UNION ALL SELECT 'global', locktype, waits FROM pg_stat_lock WHERE waits<>0;
\echo '(expect backend row present, global empty)'
SQL
wait

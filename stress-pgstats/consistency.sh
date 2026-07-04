#!/bin/bash
# Post-load consistency checks. Usage: consistency.sh <label>
source /home/user/stress/env.sh
LABEL="${1:-full}"
OUT="$LOGDIR/consistency_${LABEL}.log"
{
echo "=== consistency check $LABEL $(date -Is) ==="

echo "--- pg_stat_lock: any negative or absurd values? ---"
$PSQL -c "select locktype,waits,wait_time,fastpath_exceeded,stats_reset from pg_stat_lock
          where waits<0 or wait_time<0 or fastpath_exceeded<0 or waits>1e15 or fastpath_exceeded>1e15;"
echo "(empty above = OK)"

echo "--- pg_stat_lock full snapshot ---"
$PSQL -c "select * from pg_stat_lock order by locktype;"

echo "--- per-backend lock stats sanity (any negative) across live backends ---"
$PSQL -c "select a.pid, l.locktype, l.waits, l.wait_time, l.fastpath_exceeded
          from pg_stat_activity a, lateral pg_stat_get_backend_lock(a.pid) l
          where a.pid is not null and (l.waits<0 or l.wait_time<0 or l.fastpath_exceeded<0);"
echo "(empty above = OK)"

echo "--- pg_stat_database xact_commit / rollback for postgres db ---"
$PSQL -c "select datname, xact_commit, xact_rollback, deadlocks, stats_reset from pg_stat_database where datname='postgres';"

echo "--- current table-stat entry count (leak proxy) ---"
$PSQL -tAc "select 'tables_now='||count(*) from pg_stat_all_tables;"
$PSQL -tAc "select 'user_funcs_now='||count(*) from pg_stat_user_functions;"

echo "--- kind_info entry_count (expected NULL for all builtin kinds) ---"
$PSQL -c "select id,name,fixed_amount,entry_count from pg_stat_kind_info order by id;"
} > "$OUT" 2>&1
cat "$OUT"

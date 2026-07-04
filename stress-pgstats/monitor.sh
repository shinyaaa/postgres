#!/bin/bash
# Monitor: every 10s append a timeseries record + flag anomalies.
# Usage: monitor.sh <run_label> <duration_seconds>
source /home/user/stress/env.sh
LABEL="$1"; DUR="${2:-120}"
TS_LOG="$LOGDIR/monitor_${LABEL}.log"
ANOM_LOG="$LOGDIR/anomalies_${LABEL}.log"
PGLOG=/tmp/pg.log
: > "$TS_LOG"; : > "$ANOM_LOG"

PM=$(head -1 /home/user/pgdata/postmaster.pid 2>/dev/null)
echo "# monitor label=$LABEL dur=$DUR postmaster=$PM start=$(date -Is)" | tee -a "$TS_LOG"
echo "# t  crashes  cores  kind_entries(relation/function/index/backend/database)  pm_rss_kb  tree_rss_kb  nbackends  lock_neg_or_huge" >> "$TS_LOG"

end=$(( $(date +%s) + DUR ))
t=0
while [ "$(date +%s)" -lt "$end" ]; do
  # crash markers in server log
  crashes=$(grep -cE "TRAP|PANIC|terminated by signal|was terminated|segfault|assertion" "$PGLOG" 2>/dev/null)
  # core files (backend cwd = PGDATA; also project cores dir)
  cores=$(ls /home/user/pgdata/core* /home/user/cores/core* 2>/dev/null | wc -l)
  # stat kind entry counts (variable-amount kinds)
  kinfo=$($PSQL -tAF',' -c "select name,coalesce(entry_count,-1) from pg_stat_kind_info where name in ('relation','function','index','backend','database') order by name;" 2>/dev/null | tr '\n' ' ')
  # postmaster RSS and whole-tree RSS
  pm_rss=$(awk '/VmRSS/{print $2}' /proc/$PM/status 2>/dev/null)
  tree_rss=$(ps --ppid $PM -o rss= 2>/dev/null | awk '{s+=$1} END{print s+0}')
  nback=$($PSQL -tAc "select count(*) from pg_stat_activity;" 2>/dev/null)
  # relation/function stat-entry proxies (leak detection: should not grow unbounded)
  ntab=$($PSQL -tAc "select count(*) from pg_stat_all_tables;" 2>/dev/null)
  nfunc=$($PSQL -tAc "select count(*) from pg_stat_user_functions;" 2>/dev/null)
  # lock stats: detect negative or absurdly large values
  lockbad=$($PSQL -tAF',' -c "select locktype,waits,wait_time,fastpath_exceeded from pg_stat_lock where waits<0 or wait_time<0 or fastpath_exceeded<0 or waits>1e15 or fastpath_exceeded>1e15;" 2>/dev/null | tr '\n' ';')
  printf "%4d  crashes=%s  cores=%s  kinds=[%s] pm_rss=%s tree_rss=%s nback=%s ntab=%s nfunc=%s lockbad=[%s]\n" \
    "$t" "$crashes" "$cores" "$kinfo" "$pm_rss" "$tree_rss" "$nback" "$ntab" "$nfunc" "$lockbad" >> "$TS_LOG"

  # anomaly flags
  if [ "${crashes:-0}" -gt 0 ]; then echo "[t=$t] CRASH MARKERS in log: $crashes" >> "$ANOM_LOG"; fi
  if [ "${cores:-0}" -gt 0 ]; then echo "[t=$t] CORE DUMP(S): $cores" >> "$ANOM_LOG"; fi
  if [ -n "$lockbad" ]; then echo "[t=$t] BAD LOCK STAT VALUES: $lockbad" >> "$ANOM_LOG"; fi
  # postmaster gone?
  if ! kill -0 "$PM" 2>/dev/null; then echo "[t=$t] POSTMASTER GONE (pid $PM)" >> "$ANOM_LOG"; fi

  t=$((t+10))
  sleep 10
done
echo "# monitor end=$(date -Is)" >> "$TS_LOG"

#!/bin/bash
# (c) Hammer pg_stat_get_backend_lock(pid) for every pid in pg_stat_activity.
# Intentionally targets the race where a backend exits right after we read its pid.
source /home/user/stress/env.sh
while :; do
  pids=$($PSQL -tAc "select pid from pg_stat_activity where pid is not null;" 2>/dev/null)
  for pid in $pids; do
    # also throw in some random/near-miss pids to hit terminated-pid path harder
    $PSQL -tAc "select count(*) from pg_stat_get_backend_lock($pid);" >/dev/null 2>&1
  done
  # a batch join form too (exercises SRF within a scan over live pids)
  $PSQL -c "select a.pid, l.locktype, l.waits from pg_stat_activity a,
            lateral pg_stat_get_backend_lock(a.pid) l where a.pid is not null;" >/dev/null 2>&1
done

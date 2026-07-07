#!/bin/bash
PSQL=/home/user/pgav/bin/psql
END=$(( $(date +%s) + 1980 ))   # ~33 minutes
while [ $(date +%s) -lt $END ]; do
  now=$(date +%s)
  lpid=$($PSQL -d postgres -Atc "SELECT pid FROM pg_stat_activity WHERE backend_type='autovacuum launcher'")
  lrss=$(grep VmRSS /proc/$lpid/status 2>/dev/null | awk '{print $2}')
  echo "$now launcher pid=$lpid VmRSS_kB=$lrss"
  for w in $($PSQL -d postgres -Atc "SELECT pid FROM pg_stat_activity WHERE backend_type='autovacuum worker'"); do
    wrss=$(grep VmRSS /proc/$w/status 2>/dev/null | awk '{print $2}')
    echo "$now worker pid=$w VmRSS_kB=$wrss"
  done
  sleep 10
done

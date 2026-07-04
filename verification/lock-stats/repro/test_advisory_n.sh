#!/bin/bash
export PGI=/root/pgi
PSQL="$PGI/bin/psql -X -d postgres -A -t"
N=3
$PSQL -c "SELECT pg_stat_reset_shared('lock');" >/dev/null
TOTAL=0
for i in $(seq 1 $N); do
  $PSQL -c "SELECT pg_advisory_lock(42); SELECT pg_sleep(2); SELECT pg_advisory_unlock(42);" >/dev/null 2>&1 &
  APID=$!
  sleep 0.4
  START=$(date +%s.%N)
  $PSQL -c "SELECT pg_advisory_lock(42); SELECT pg_advisory_unlock(42);" >/dev/null 2>&1
  END=$(date +%s.%N)
  wait $APID
  W=$(echo "$END - $START" | bc)
  TOTAL=$(echo "$TOTAL + $W" | bc)
  echo "iter $i: B waited ${W}s"
done
echo "SUM measured B wait (s): $TOTAL   (~ms: $(echo "$TOTAL*1000" | bc))"
$PSQL -c "SELECT pg_stat_force_next_flush();" >/dev/null
sleep 1
echo "--- global pg_stat_lock (advisory) ---"
$PGI/bin/psql -X -d postgres -c "SELECT locktype, waits, wait_time FROM pg_stat_lock WHERE locktype='advisory';"

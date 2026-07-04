#!/bin/bash
export PGI=/root/pgi
PSQL="$PGI/bin/psql -X -d postgres -A -t"
$PSQL -c "DROP TABLE IF EXISTS lktest; CREATE TABLE lktest(id int primary key, v int); INSERT INTO lktest VALUES (1,0);" >/dev/null
$PSQL -c "SELECT pg_stat_reset_shared('lock');" >/dev/null
N=2
for i in $(seq 1 $N); do
  # Session A holds row lock for 3s inside a transaction
  $PSQL -c "BEGIN; UPDATE lktest SET v=v+1 WHERE id=1; SELECT pg_sleep(3); COMMIT;" >/dev/null 2>&1 &
  APID=$!
  sleep 0.5
  START=$(date +%s.%N)
  $PSQL -c "UPDATE lktest SET v=v+1 WHERE id=1;" >/dev/null 2>&1
  END=$(date +%s.%N)
  wait $APID
  echo "iter $i: B waited $(echo "$END - $START" | bc)s"
done
$PSQL -c "SELECT pg_stat_force_next_flush();" >/dev/null
sleep 1
echo "--- global pg_stat_lock (nonzero) ---"
$PGI/bin/psql -X -d postgres -c "SELECT locktype, waits, wait_time FROM pg_stat_lock WHERE waits>0 OR wait_time>0 ORDER BY locktype;"

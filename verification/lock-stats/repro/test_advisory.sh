#!/bin/bash
export PGI=/root/pgi
PSQL="$PGI/bin/psql -X -d postgres -A -t"
echo "=== ADVISORY LOCK WAIT TEST ==="
# Session A: acquire advisory lock 42, hold 3s, release
$PSQL -c "SELECT pg_advisory_lock(42); SELECT pg_sleep(3); SELECT pg_advisory_unlock(42);" > /home/pgtest/sessA.out 2>&1 &
APID=$!
sleep 0.5   # ensure A holds the lock first
# Session B: try to acquire same lock -> blocks until A releases (~2.5s)
START=$(date +%s.%N)
$PSQL -c "SELECT pg_advisory_lock(42); SELECT pg_advisory_unlock(42);" > /home/pgtest/sessB.out 2>&1
END=$(date +%s.%N)
wait $APID
echo "B measured wait (s): $(echo "$END - $START" | bc)"

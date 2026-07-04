#!/bin/bash
export PGI=/root/pgi
PSQL="$PGI/bin/psql -X -d postgres -A -t"
$PSQL -c "SELECT pg_stat_reset_shared('lock');" >/dev/null
# Hold advisory lock only 0.5s (< deadlock_timeout=1s)
$PSQL -c "SELECT pg_advisory_lock(77); SELECT pg_sleep(0.5); SELECT pg_advisory_unlock(77);" >/dev/null 2>&1 &
A=$!; sleep 0.1
START=$(date +%s.%N)
$PSQL -c "SELECT pg_advisory_lock(77); SELECT pg_advisory_unlock(77);" >/dev/null 2>&1
END=$(date +%s.%N)
wait $A
echo "SHORT wait: B waited $(echo "$END-$START"|bc)s (< deadlock_timeout 1s)"
$PSQL -c "SELECT pg_stat_force_next_flush();" >/dev/null; sleep 1
echo "advisory stat after SHORT wait:"
$PGI/bin/psql -X -d postgres -c "SELECT locktype,waits,wait_time FROM pg_stat_lock WHERE locktype='advisory';"

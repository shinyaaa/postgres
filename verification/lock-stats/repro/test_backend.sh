#!/bin/bash
export PGI=/root/pgi
PSQL="$PGI/bin/psql -X -d postgres -A -t"
FIFO=/home/pgtest/bpipe
rm -f $FIFO; mkfifo $FIFO
# Reset lock stats so only B contributes to advisory
$PSQL -c "SELECT pg_stat_reset_shared('lock');" >/dev/null
# Persistent session B, driven by FIFO
$PSQL > /home/pgtest/B.out 2>&1 < $FIFO &
BSHELL=$!
exec 3>$FIFO          # keep write end open
echo "SELECT pg_backend_pid();" >&3
sleep 1
BPID=$(grep -E '^[0-9]+$' /home/pgtest/B.out | head -1)
echo "B backend pid = $BPID"
# Session A holds advisory lock 99 for 3s
$PSQL -c "SELECT pg_advisory_lock(99); SELECT pg_sleep(3); SELECT pg_advisory_unlock(99);" >/dev/null 2>&1 &
APID=$!
sleep 0.5
# B tries to acquire -> waits ~2.5s. Send and wait for it to finish.
echo "SELECT pg_advisory_lock(99); SELECT pg_advisory_unlock(99); SELECT 'B_DONE';" >&3
# wait until B_DONE appears
for i in $(seq 1 60); do grep -q B_DONE /home/pgtest/B.out && break; sleep 0.2; done
wait $APID
# Force B to flush its own stats
echo "SELECT pg_stat_force_next_flush(); SELECT 'FLUSHED';" >&3
for i in $(seq 1 30); do grep -q FLUSHED /home/pgtest/B.out && break; sleep 0.2; done
sleep 1
echo "=== GLOBAL pg_stat_lock (advisory) ==="
$PGI/bin/psql -X -d postgres -c "SELECT locktype,waits,wait_time FROM pg_stat_lock WHERE locktype='advisory';"
echo "=== BACKEND pg_stat_get_backend_lock($BPID) (nonzero) ==="
$PGI/bin/psql -X -d postgres -c "SELECT locktype,waits,wait_time FROM pg_stat_get_backend_lock($BPID) WHERE waits>0 OR wait_time>0;"
echo "BPID=$BPID" > /home/pgtest/bpid.txt
# keep B alive: leave fd 3 open? We must close to let script end, but keep session for next test.
# Close B session now.
echo "\\q" >&3
exec 3>&-
wait $BSHELL 2>/dev/null

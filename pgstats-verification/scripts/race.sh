#!/bin/bash
# Reset-during-lock-wait race: does a post-reset flush of stale pending
# produce negative/overflow values in pg_stat_lock?
source /home/claude/pgwork/env.sh
FIFO=/home/claude/pgwork/bfifo
rm -f $FIFO; mkfifo $FIFO

# Ensure lock stats start clean
$PSQL -q -c "SELECT pg_stat_reset_shared('lock'); SELECT pg_stat_force_next_flush();" >/dev/null 2>&1

# Session A: hold ACCESS EXCLUSIVE for 2s
$PSQL -q -c "BEGIN; LOCK TABLE fill_t IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 &

sleep 0.5
# Session B: controlled via FIFO. It BEGINs, blocks on the lock, and after
# unblocking stays idle-in-transaction until we push COMMIT through the FIFO.
( $PSQL -q -f $FIFO >/home/claude/pgwork/bout.txt 2>&1 ) &
# feed B: begin + the blocking select (will wait for A to release ~t=2.5)
exec 3>$FIFO
echo "BEGIN;" >&3
echo "SELECT count(*) FROM fill_t;" >&3   # blocks until A commits, then counts a wait
# give B time to unblock and register the wait into local pending
sleep 3
echo "--- B unblocked, wait counted into pending (not yet flushed) ---"

# Session C: reset lock stats NOW (before B flushes)
$PSQL -q -c "SELECT pg_stat_reset_shared('lock'); SELECT pg_stat_force_next_flush();" >/dev/null 2>&1
echo "--- lock stats reset while B holds stale pending ---"
$PSQL -tAF'|' -c "SELECT locktype, waits, wait_time, fastpath_exceeded FROM pg_stat_lock WHERE waits<>0 OR wait_time<>0 ORDER BY locktype;"
echo "(above: state immediately after reset, before B commits)"

# Now let B commit -> flushes stale pending onto freshly-reset shared
echo "SELECT pg_stat_force_next_flush();" >&3
echo "COMMIT;" >&3
echo "\\q" >&3
exec 3>&-
sleep 1

echo "--- after B flushed stale pending post-reset ---"
$PSQL -tAF'|' -c "SELECT locktype, waits, wait_time, fastpath_exceeded FROM pg_stat_lock WHERE waits<>0 OR wait_time<>0 ORDER BY locktype;"
echo "--- any negative or overflow values across pg_stat_lock? ---"
$PSQL -tAF'|' -c "SELECT locktype, waits, wait_time FROM pg_stat_lock WHERE waits < 0 OR wait_time < 0;"
echo "(empty = no negatives)"
wait
rm -f $FIFO

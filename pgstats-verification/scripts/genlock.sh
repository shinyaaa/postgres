#!/bin/bash
# Generate at least one heavyweight-lock wait so pg_stat_lock.waits > 0.
source /home/claude/pgwork/env.sh
# Session A: hold ACCESS EXCLUSIVE on fill_t, then release after 3s.
$PSQL -c "BEGIN; LOCK TABLE fill_t IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(3); COMMIT;" >/dev/null 2>&1 &
AP=$!
sleep 0.5
# Session B: contend -> must wait in the lock queue -> counts a wait on commit.
$PSQL -c "SELECT count(*) FROM fill_t;" >/dev/null 2>&1
wait $AP
$PSQL -c "SELECT pg_stat_force_next_flush();" >/dev/null 2>&1

#!/bin/bash
# (f) Fast-path overflow generator: each txn takes 40 weak relation locks into a
# single fast-path group (max_locks_per_transaction=16 => 1 group). Drives
# pgstat_count_lock_fastpath_exceeded() continuously, concurrently with resets/reads.
source /home/user/stress/env.sh
while :; do
  $PSQL -q -f /home/user/stress/fpx_lock.sql >/dev/null 2>&1
done

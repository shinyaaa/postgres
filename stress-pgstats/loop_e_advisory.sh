#!/bin/bash
# (e) Create advisory-lock contention every ~2s -> generates lock waits ->
# concurrent updates to lock statistics (both shared PGSTAT_KIND_LOCK and per-backend).
source /home/user/stress/env.sh
holder() {
  $PSQL -c "select pg_advisory_lock(4242); select pg_sleep(0.3); select pg_advisory_unlock(4242);" >/dev/null 2>&1
}
waiter() {
  # small delay so it blocks on the holder, producing a real lock wait
  sleep 0.05
  $PSQL -c "select pg_advisory_lock(4242); select pg_advisory_unlock(4242);" >/dev/null 2>&1
}
while :; do
  holder &
  waiter &
  waiter &
  waiter &
  wait
  sleep 2
done

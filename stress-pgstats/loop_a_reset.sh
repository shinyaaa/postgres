#!/bin/bash
# (a) Reset stats every ~0.2s: local + all shared kinds incl. custom 'lock'
source /home/user/stress/env.sh
while :; do
  $PSQL -c "select pg_stat_reset();" >/dev/null 2>&1
  $PSQL -c "select pg_stat_reset_shared(NULL);" >/dev/null 2>&1
  $PSQL -c "select pg_stat_reset_shared('io');" >/dev/null 2>&1
  $PSQL -c "select pg_stat_reset_shared('lock');" >/dev/null 2>&1
  # also churn backend-level and single-object resets to stress reset paths
  $PSQL -tAc "select pg_stat_reset_backend_stats(pid) from pg_stat_activity where pid is not null limit 5;" >/dev/null 2>&1
  sleep 0.2
done

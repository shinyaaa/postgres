#!/bin/bash
# (b) Continuously SELECT every pg_stat view (incl. custom pg_stat_lock, pg_stat_kind_info)
source /home/user/stress/env.sh
while :; do
  $PSQL \
    -c "select * from pg_stat_lock;" \
    -c "select * from pg_stat_kind_info;" \
    -c "select * from pg_stat_activity;" \
    -c "select * from pg_stat_database;" \
    -c "select * from pg_stat_all_tables;" \
    -c "select * from pg_stat_all_indexes;" \
    -c "select * from pg_stat_user_functions;" \
    -c "select * from pg_stat_io;" \
    -c "select * from pg_stat_bgwriter;" \
    -c "select * from pg_stat_checkpointer;" \
    -c "select * from pg_stat_wal;" \
    -c "select * from pg_stat_slru;" \
    -c "select * from pg_stat_replication;" \
    -c "select * from pg_stat_subscription;" \
    >/dev/null 2>&1
done

#!/bin/bash
# Self-contained autovacuum boundary/stress battery (X1-X4) from initdb.
# No anomaly was found in the reference run; this reproduces the full battery.
#
# Prereqs: a PostgreSQL master build installed under $PREFIX, run as a
# non-root OS user that owns $PGDATA (PostgreSQL refuses to run as root).
#
# Usage:  PREFIX=$HOME/pgav PGDATA=$HOME/pgav-data5 bash repro.sh
set -u
PREFIX=${PREFIX:-$HOME/pgav}
PGDATA=${PGDATA:-$HOME/pgav-data5}
export PATH="$PREFIX/bin:$PATH"
PSQL="psql -d postgres"
say(){ echo -e "\n=== $* ==="; }

say "init cluster"
rm -rf "$PGDATA"
initdb -D "$PGDATA" --no-locale -E UTF8
cat >> "$PGDATA/postgresql.conf" <<'EOF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
logging_collector = on
log_directory = 'log'
autovacuum_vacuum_cost_delay = 0
autovacuum_work_mem = 1MB
EOF
pg_ctl -D "$PGDATA" -l "$PGDATA/start.log" -w start
LOGDIR="$PGDATA/log"

########################################################################
say "X1: multiple index-vacuum passes under 1MB TidStore"
$PSQL <<'EOF'
CREATE TABLE mp(a int, b text);
INSERT INTO mp SELECT g, md5(g::text) FROM generate_series(1,5000000) g;
CREATE INDEX mp_a ON mp(a);
CREATE INDEX mp_b ON mp(b);
DELETE FROM mp WHERE a % 2 = 0;
EOF
# sample progress until mp's autovacuum completes
( for i in $(seq 1 360); do
    $PSQL -Atc "SELECT '$i '||phase||' idx_vac_count='||index_vacuum_count||' max_dtb='||max_dead_tuple_bytes FROM pg_stat_progress_vacuum WHERE relid='mp'::regclass"
    sleep 2
  done ) > x1-progress.log 2>&1 &
MON=$!
for i in $(seq 1 600); do
  [ "$($PSQL -Atc "SELECT last_autovacuum IS NOT NULL FROM pg_stat_user_tables WHERE relname='mp'")" = t ] && break; sleep 1
done
kill $MON 2>/dev/null
say "X1 result (expect: index scans >= 2, 'across N resets (limit 1.00 MB each)')"
grep -A14 'automatic vacuum of table.*\.mp": index scans' "$LOGDIR"/*.log | grep -E 'index scans|resets'

########################################################################
say "X2: self-cancel on lock conflict (throttle cx to open a race window)"
$PSQL -c "CREATE TABLE cx(a int, b text);
          INSERT INTO cx SELECT g, md5(g::text) FROM generate_series(1,3000000) g;
          DELETE FROM cx WHERE a % 2 = 0;"
# wait for the (fast) initial autovacuum to finish, then throttle + re-trigger
sleep 8
$PSQL -c "ALTER TABLE cx SET (autovacuum_vacuum_cost_delay=20, autovacuum_vacuum_cost_limit=100,
                              autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_threshold=1000);
          DELETE FROM cx WHERE a % 4 = 1;"
for i in $(seq 1 100); do
  [ -n "$($PSQL -Atc "SELECT pid FROM pg_stat_progress_vacuum WHERE relid='cx'::regclass")" ] && break
  sleep 0.1
done
say "issuing ACCESS EXCLUSIVE LOCK (expect: acquired in ~1s, 'canceling autovacuum task' in log)"
/usr/bin/time -f "LOCK elapsed=%es" timeout 60 $PSQL -c "LOCK TABLE cx IN ACCESS EXCLUSIVE MODE; SELECT 1;" 2>&1
grep 'canceling autovacuum task' "$LOGDIR"/*.log | tail -1

########################################################################
say "X3a: SIGKILL a worker mid-vacuum -> crash recovery"
$PSQL -c "DELETE FROM cx WHERE a % 8 = 3;"
WPID=""
for i in $(seq 1 150); do
  WPID=$($PSQL -Atc "SELECT pid FROM pg_stat_progress_vacuum WHERE relid='cx'::regclass")
  [ -n "$WPID" ] && break; sleep 0.1
done
echo "killing worker $WPID"; kill -9 "$WPID"
sleep 3
for i in $(seq 1 120); do $PSQL -Atc "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
say "X3a result (expect: 'redo done', 'ready to accept', no PANIC/TRAP)"
grep -E 'terminated by signal 9|redo done|ready to accept|PANIC|TRAP' "$LOGDIR"/*.log | tail -5

say "X3b: immediate shutdown mid-vacuum -> crash recovery"
$PSQL -c "ALTER TABLE cx SET (autovacuum_vacuum_cost_delay=20, autovacuum_vacuum_cost_limit=100);"
$PSQL -c "INSERT INTO cx SELECT g, md5(g::text) FROM generate_series(1,1000000) g; DELETE FROM cx WHERE a % 2 = 0;"
for i in $(seq 1 150); do
  [ -n "$($PSQL -Atc "SELECT pid FROM pg_stat_progress_vacuum WHERE relid='cx'::regclass")" ] && break; sleep 0.1
done
pg_ctl -D "$PGDATA" -m immediate stop
pg_ctl -D "$PGDATA" -l "$PGDATA/start2.log" -w start
say "X3b result (expect: 'redo done', 'ready to accept', no PANIC/TRAP)"
grep -E 'redo done|ready to accept|PANIC|TRAP' "$LOGDIR"/*.log | tail -3

########################################################################
say "X4: 30-min churn + launcher RSS leak monitoring"
$PSQL -c "DROP TABLE IF EXISTS mp; DROP TABLE IF EXISTS cx;"
pgbench -i -s 50 postgres
( END=$(( $(date +%s) + 1980 ))
  while [ $(date +%s) -lt $END ]; do
    L=$($PSQL -Atc "SELECT pid FROM pg_stat_activity WHERE backend_type='autovacuum launcher'")
    echo "$(date +%s) launcher pid=$L VmRSS_kB=$(awk '/VmRSS/{print $2}' /proc/$L/status 2>/dev/null)"
    for w in $($PSQL -Atc "SELECT pid FROM pg_stat_activity WHERE backend_type='autovacuum worker'"); do
      echo "$(date +%s) worker pid=$w VmRSS_kB=$(awk '/VmRSS/{print $2}' /proc/$w/status 2>/dev/null)"
    done
    sleep 10
  done ) > rss.log 2>&1 &
RSSMON=$!
pgbench -T 1800 -c 8 -j 4 postgres; echo "PGBENCH_EXIT=$?"
kill $RSSMON 2>/dev/null
say "X4 result (expect: pgbench rc0/0 failed, autovacuum ran, launcher RSS flat, 0 PANIC/TRAP)"
grep launcher rss.log | awk -F'VmRSS_kB=' 'NR==1{print "first="$2} {last=$2} END{print "last="last}'
grep -oE 'automatic vacuum of table "postgres\.public\.pgbench_[a-z]+"' "$LOGDIR"/*.log | sort | uniq -c
echo "PANIC/TRAP count: $(grep -cE 'PANIC|TRAP' "$LOGDIR"/*.log)"
say "DONE"

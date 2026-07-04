#!/bin/bash
#
# Self-contained reproduction for empirically verifying PostgreSQL master's
# autovacuum XID-wraparound protections (W1-W4) using the xid_wraparound test
# module's consume_xids() to actually burn XIDs.
#
# Usage:
#   PREFIX=$HOME/pgav  DATA=$HOME/pgav-data4  bash repro.sh
# Must be run as a NON-root user. Requires a git checkout of postgres master.
#
set -e
SRC=${SRC:-$HOME/pgsrc}
PREFIX=${PREFIX:-$HOME/pgav}
DATA=${DATA:-$HOME/pgav-data4}
export PATH=$PREFIX/bin:$PATH
export PGDATA=$DATA
ulimit -c unlimited

# --- build (skip if already installed) ---
if [ ! -x "$PREFIX/bin/postgres" ]; then
  cd "$SRC"
  ./configure --prefix="$PREFIX" --enable-debug --enable-cassert CFLAGS="-O0 -g3"
  make -j"$(nproc)" && make install
  make -C src/test/modules/xid_wraparound install
  make -C contrib/pg_visibility install
fi

# --- init + config ---
rm -rf "$DATA"
initdb -D "$DATA" --no-locale -E UTF8 >/dev/null
cat >> "$DATA/postgresql.conf" <<'EOF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
logging_collector = on
log_directory = 'log'
autovacuum_freeze_max_age = 200000
vacuum_freeze_min_age = 0
vacuum_freeze_table_age = 0
autovacuum_vacuum_cost_delay = 0
EOF
pg_ctl -D "$DATA" -l "$HOME/p4-start.log" start
sleep 2
psql -d postgres -c "CREATE EXTENSION xid_wraparound;"
psql -d postgres -c "CREATE EXTENSION pg_visibility;"

# IMPORTANT: consume_xids() bumps nextXid via a shortcut but does NOT advance
# latestCompletedXid. On an otherwise idle cluster the xmin horizon stays pinned
# at its pre-consume value, so VACUUM cannot lower relfrozenxid and age looks
# "stuck" even though anti-wraparound vacuum is firing. A live DB never stalls
# because ongoing transactions advance the horizon. This ticker emulates that.
( while true; do psql -d postgres -Atc "SELECT txid_current();" >/dev/null 2>&1; sleep 0.5; done ) &
TICKER=$!
trap 'kill $TICKER 2>/dev/null' EXIT

echo "### W1: anti-wraparound vacuum forced firing (incl. autovacuum_enabled=off) ###"
psql -d postgres <<'EOF'
CREATE TABLE frozen_target(a int) WITH (autovacuum_enabled = off);
INSERT INTO frozen_target SELECT generate_series(1,100000);
EOF
psql -d postgres -c "SELECT consume_xids(300000);"
for i in $(seq 1 300); do
  a=$(psql -d postgres -Atc "SELECT max(age(datfrozenxid)) FROM pg_database")
  [ "$a" -lt 200000 ] && { echo "W1 ADVANCED at ${i}s (age=$a)"; break; }
  sleep 1
done
grep 'to prevent wraparound' "$DATA"/log/*.log | grep frozen_target | head -1

echo "### W2: failsafe firing ###"
psql -d postgres -c "ALTER SYSTEM SET vacuum_failsafe_age = 300000;"
psql -d postgres -c "SELECT pg_reload_conf();"; sleep 1
psql -d postgres <<'EOF'
CREATE TABLE fs(a int, b text);
INSERT INTO fs SELECT g, md5(g::text) FROM generate_series(1,2000000) g;
CREATE INDEX ON fs(b);
DELETE FROM fs WHERE a % 2 = 0;
EOF
psql -d postgres -c "SELECT consume_xids(400000);"
for i in $(seq 1 180); do grep -qi bypassing "$DATA"/log/*.log && { echo "W2 FAILSAFE at ${i}s"; break; }; sleep 1; done
grep 'as a failsafe' "$DATA"/log/*.log | grep '"postgres.public.fs"' | head -1

echo "### W3: anti-wraparound vacuum not self-cancelled on lock conflict ###"
psql -d postgres -c "ALTER SYSTEM SET vacuum_failsafe_age = 1600000000;"
psql -d postgres -c "SELECT pg_reload_conf();"; sleep 1
psql -d postgres <<'EOF'
CREATE TABLE aw(a int, b text) WITH (autovacuum_vacuum_cost_delay=10, autovacuum_vacuum_cost_limit=300);
INSERT INTO aw SELECT g, md5(g::text) FROM generate_series(1,5000000) g;
CREATE INDEX ON aw(b);
DELETE FROM aw WHERE a % 3 = 0;
EOF
psql -d postgres -c "SELECT consume_xids(400000);" >/dev/null
for i in $(seq 1 120); do
  r=$(psql -d postgres -Atc "SELECT p.phase FROM pg_stat_progress_vacuum p JOIN pg_class c ON c.oid=p.relid WHERE c.relname='aw'")
  [ -n "$r" ] && { echo "aw wraparound vacuum in progress ($r)"; break; }; sleep 1
done
# NOTE: LOCK must be inside a transaction block, else psql errors immediately.
t0=$(date +%s)
timeout 120 psql -d postgres -c 'BEGIN; LOCK TABLE aw IN ACCESS EXCLUSIVE MODE; SELECT clock_timestamp() AS acquired; COMMIT;'
echo "W3 LOCK acquired after $(( $(date +%s) - t0 ))s (waited for vacuum; should be >0)"
echo -n "W3 canceling-autovacuum-task count (must be 0): "; cat "$DATA"/log/*.log | grep -c 'canceling autovacuum task' || echo 0

echo "### W4: age recovery under high age (fresh unfrozen data) ###"
psql -d postgres <<'EOF'
CREATE TABLE big2(a int, b text) WITH (autovacuum_vacuum_cost_delay=2, autovacuum_vacuum_cost_limit=150);
INSERT INTO big2 SELECT g, md5(g::text) FROM generate_series(1,3000000) g;
EOF
psql -d postgres -c "SELECT consume_xids(10000000);" >/dev/null
echo "W4 PEAK big2 age=$(psql -d postgres -Atc "SELECT age(relfrozenxid) FROM pg_class WHERE relname='big2'")"
for i in $(seq 1 900); do
  b=$(psql -d postgres -Atc "SELECT age(relfrozenxid) FROM pg_class WHERE relname='big2'")
  [ "$b" -lt 200000 ] && { echo "W4 RECOVERED at ${i}s (big2 age=$b)"; break; }; sleep 1
done

echo "### Invariants ###"
echo -n "TRAP/PANIC/signal (must be 0): "; cat "$DATA"/log/*.log | grep -cE 'TRAP:|PANIC|terminated by signal' || echo 0
for t in aw big2 fs frozen_target; do
  echo "pg_check_frozen($t)=$(psql -d postgres -Atc "SELECT count(*) FROM pg_check_frozen('$t')") pg_check_visible($t)=$(psql -d postgres -Atc "SELECT count(*) FROM pg_check_visible('$t')")"
done

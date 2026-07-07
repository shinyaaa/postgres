#!/bin/bash
#
# repro.sh — Empirical verification of autovacuum XID-wraparound protection on
# PostgreSQL master, driving real XID consumption via the xid_wraparound test module.
#
# Covers W1..W4 (anti-wraparound / failsafe / no-self-cancel / catch-up) and
# X1..X3 (TidStore multi-pass / normal-vacuum self-cancel / crash recovery).
# X4 (long churn + launcher RSS leak watch) is included as an optional tail.
#
# IMPORTANT FINDING baked into this script:
#   consume_xids() burns XIDs by bumping TransamVariables->nextXid directly
#   (consume_xids_shortcut) WITHOUT committing those XIDs. Only the consume
#   transaction's own top XID commits, so latestCompletedXid / OldestXmin stays
#   pinned near that XID. Vacuum then runs but CANNOT advance relfrozenxid past
#   OldestXmin, and age(datfrozenxid) appears "stuck". This is NOT a bug: it is
#   how the tool works. To let freezing advance you MUST run one real committed
#   write afterward to move latestCompletedXid forward. The upstream TAP test
#   src/test/modules/xid_wraparound/t/001_emergency_vacuum.pl does exactly this
#   ("Make sure the latest completed XID is advanced" -> INSERT).
#
# Run as a NON-root user. Requires the build below (or an existing install on PATH).
set -uo pipefail

# ---------------------------------------------------------------------------
# 0. Build (skip if PostgreSQL master with the test modules is already on PATH)
# ---------------------------------------------------------------------------
build() {
  sudo apt-get update
  sudo apt-get install -y build-essential bison flex libreadline-dev zlib1g-dev \
      libicu-dev pkg-config gdb strace bc
  git clone https://git.postgresql.org/git/postgresql.git ~/pgsrc
  cd ~/pgsrc && git checkout master
  ./configure --prefix="$HOME/pgav" --enable-debug --enable-cassert CFLAGS="-O0 -g3"
  make -j"$(nproc)" && make install
  make -C src/test/modules/xid_wraparound install
  make -C contrib/pg_visibility install
}
[ "${DO_BUILD:-0}" = 1 ] && build

export PATH="$HOME/pgav/bin:$PATH"
PGDATA="$HOME/pgav-wrap-data"
ulimit -c unlimited
Q(){ psql -d postgres -Atc "$1"; }

# ---------------------------------------------------------------------------
# 1. Fresh cluster
# ---------------------------------------------------------------------------
pg_ctl -D "$PGDATA" -m immediate stop 2>/dev/null || true
rm -rf "$PGDATA"
initdb -D "$PGDATA" --no-locale -E UTF8
cat >> "$PGDATA/postgresql.conf" <<EOF
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
logging_collector = on
log_directory = 'log'
autovacuum_freeze_max_age = 200000
vacuum_freeze_min_age = 0
vacuum_freeze_table_age = 0
autovacuum_vacuum_cost_delay = 0
autovacuum_work_mem = 1MB
EOF
pg_ctl -D "$PGDATA" -l "$HOME/pgav-wrap-start.log" start
sleep 1
psql -d postgres -c "CREATE EXTENSION xid_wraparound;"
psql -d postgres -c "CREATE EXTENSION pg_visibility;"

# ---------------------------------------------------------------------------
# W1: forced anti-wraparound vacuum, incl. autovacuum_enabled=off table
# ---------------------------------------------------------------------------
echo "===== W1 ====="
psql -d postgres <<'EOF'
CREATE TABLE frozen_target(a int) WITH (autovacuum_enabled = off);
INSERT INTO frozen_target SELECT generate_series(1,100000);
EOF
psql -d postgres -c "SELECT consume_xids(300000);"
echo "after consume, age (expected ~300000, STUCK until we advance latestCompletedXid):"
Q "SELECT max(age(datfrozenxid)) FROM pg_database"
# THE KEY STEP the naive procedure omits: advance latestCompletedXid.
psql -d postgres -c "CREATE TABLE _adv1(x int); INSERT INTO _adv1 VALUES (1);"
for i in $(seq 1 120); do
  a=$(Q "SELECT max(age(datfrozenxid)) FROM pg_database")
  [ "$a" -lt 200000 ] && { echo "W1 ADVANCED at ${i}s, age=$a"; break; }
  sleep 1
done
grep -h "to prevent wraparound of table .*frozen_target" "$PGDATA"/log/*.log | tail -1
echo "frozen_target age (expect 0): $(Q "SELECT age(relfrozenxid) FROM pg_class WHERE relname='frozen_target'")"

# ---------------------------------------------------------------------------
# W2: failsafe firing
# ---------------------------------------------------------------------------
echo "===== W2 ====="
psql -d postgres -c "ALTER SYSTEM SET vacuum_failsafe_age = 300000; SELECT pg_reload_conf();"
psql -d postgres <<'EOF'
CREATE TABLE fs(a int, b text);
INSERT INTO fs SELECT g, md5(g::text) FROM generate_series(1,2000000) g;
CREATE INDEX ON fs(b);
DELETE FROM fs WHERE a % 2 = 0;
EOF
psql -d postgres -c "SELECT consume_xids(400000);"
psql -d postgres -c "INSERT INTO fs(a,b) VALUES (999999999,'x');"   # advance latestCompletedXid
for i in $(seq 1 90); do
  c=$(Q "SELECT autovacuum_count FROM pg_stat_all_tables WHERE relname='fs'")
  [ "${c:-0}" -ge 1 ] && break; sleep 1
done
grep -h 'bypassing nonessential maintenance of table "postgres.public.fs"' "$PGDATA"/log/*.log | tail -1

# ---------------------------------------------------------------------------
# W3: anti-wraparound vacuum is NOT self-cancelled by a conflicting lock
# ---------------------------------------------------------------------------
echo "===== W3 ====="
psql -d postgres -c "ALTER SYSTEM SET vacuum_failsafe_age = 1600000000; SELECT pg_reload_conf();"
psql -d postgres <<'EOF'
CREATE TABLE aw(a int, b text) WITH (autovacuum_enabled=off);
INSERT INTO aw SELECT g, md5(g::text) FROM generate_series(1,5000000) g;
CREATE INDEX aw_b ON aw(b);
DELETE FROM aw WHERE a % 2 = 0;   -- 2.5M dead persist (autovacuum off)
EOF
psql -d postgres -c "SELECT consume_xids(300000);"
psql -d postgres -c "INSERT INTO aw(a,b) VALUES (-1,'z');"          # advance latestCompletedXid
for i in $(seq 1 60); do
  p=$(Q "SELECT phase FROM pg_stat_progress_vacuum v JOIN pg_class c ON c.oid=v.relid WHERE c.relname='aw'")
  [ -n "$p" ] && { echo "aw wraparound vacuum in progress: $p"; break; }
  sleep 0.2
done
t0=$(date +%s.%N)
psql -d postgres -c "SET lock_timeout='30s'; LOCK TABLE aw IN ACCESS EXCLUSIVE MODE; SELECT 'GOT_LOCK';"
echo "LOCK waited $(echo "$(date +%s.%N) - $t0" | bc)s (expect several seconds; vacuum must COMPLETE first)"
echo "canceling autovacuum task count (expect 0 for aw): $(grep -c 'canceling autovacuum task' "$PGDATA"/log/*.log | paste -sd+ | bc)"

# ---------------------------------------------------------------------------
# W4: catch-up health after a big jump
# ---------------------------------------------------------------------------
echo "===== W4 ====="
psql -d postgres -c "SELECT consume_xids(10000000);"
psql -d postgres -c "INSERT INTO aw(a,b) VALUES (-2,'y');"          # advance latestCompletedXid
echo "peak age: $(Q "SELECT max(age(datfrozenxid)) FROM pg_database")"
for i in $(seq 1 900); do
  a=$(Q "SELECT max(age(datfrozenxid)) FROM pg_database")
  [ "$a" -lt 200000 ] && { echo "W4 caught up at ${i}s, age=$a"; break; }
  sleep 1
done

# ---------------------------------------------------------------------------
# X1: low-memory (1MB) forces multi-pass index vacuum (TidStore)
# ---------------------------------------------------------------------------
echo "===== X1 ====="
psql -d postgres <<'EOF'
CREATE TABLE mp(a int, b text);
INSERT INTO mp SELECT g, md5(g::text) FROM generate_series(1,5000000) g;
CREATE INDEX mp_a ON mp(a); CREATE INDEX mp_b ON mp(b);
VACUUM (FREEZE) mp;
DELETE FROM mp WHERE a % 2 = 0;
EOF
seen=0
for i in $(seq 1 600); do
  row=$(Q "SELECT 'idx_cnt='||index_vacuum_count||' max_dead_bytes='||max_dead_tuple_bytes FROM pg_stat_progress_vacuum v JOIN pg_class c ON c.oid=v.relid WHERE c.relname='mp'")
  [ -n "$row" ] && { echo "$row"; seen=1; }
  [ "$seen" = 1 ] && [ -z "$row" ] && break
  sleep 0.5
done
grep -h 'vacuum of table "postgres.public.mp": index scans' "$PGDATA"/log/*.log | tail -1  # expect index scans >= 2

# ---------------------------------------------------------------------------
# X2: a NORMAL vacuum self-cancels on lock conflict (contrast with W3)
# ---------------------------------------------------------------------------
echo "===== X2 ====="
psql -d postgres <<'EOF'
CREATE TABLE cx(a int, b text);
INSERT INTO cx SELECT g, md5(g::text) FROM generate_series(1,3000000) g;
CREATE INDEX cx_b ON cx(b);
VACUUM (FREEZE) cx;
DELETE FROM cx WHERE a % 2 = 0;
EOF
for i in $(seq 1 120); do
  p=$(Q "SELECT phase FROM pg_stat_progress_vacuum v JOIN pg_class c ON c.oid=v.relid WHERE c.relname='cx'")
  [ -n "$p" ] && break; sleep 0.2
done
t0=$(date +%s.%N)
timeout 70 psql -d postgres -c "LOCK TABLE cx IN ACCESS EXCLUSIVE MODE; SELECT 'GOT_LOCK';"
echo "LOCK waited $(echo "$(date +%s.%N) - $t0" | bc)s (expect ~1s = deadlock_timeout)"
grep -hA1 'canceling autovacuum task' "$PGDATA"/log/*.log | tail -2   # expect cx cancel

# ---------------------------------------------------------------------------
# X3: crash recovery (SIGKILL a worker mid-vacuum, then immediate shutdown)
# ---------------------------------------------------------------------------
echo "===== X3 ====="
psql -d postgres -c "DELETE FROM cx WHERE a % 4 = 1;"  # fresh dead tuples
wpid=""
for i in $(seq 1 300); do
  wpid=$(Q "SELECT v.pid FROM pg_stat_progress_vacuum v JOIN pg_class c ON c.oid=v.relid WHERE c.relname='cx'")
  [ -n "$wpid" ] && break; sleep 0.1
done
echo "SIGKILL worker $wpid"; kill -9 "$wpid"
for i in $(seq 1 120); do psql -d postgres -Atc "SELECT 1" >/dev/null 2>&1 && { echo "recovered after ~${i}x0.5s"; break; }; sleep 0.5; done
grep -hE "terminated by signal 9|automatic recovery in progress|redo done|ready to accept" "$PGDATA"/log/*.log | tail -4
pg_ctl -D "$PGDATA" -m immediate stop
pg_ctl -D "$PGDATA" -l "$HOME/pgav-wrap-start2.log" start; sleep 2
psql -d postgres -Atc "SELECT 1" >/dev/null && echo "immediate-shutdown crossing recovered OK"

echo "===== crash-assert check (expect 0) ====="
grep -hcE "TRAP:|PANIC|was terminated by signal 11|was terminated by signal 6" "$PGDATA"/log/*.log | paste -sd+ | bc

# ---------------------------------------------------------------------------
# X4 (optional): long churn + launcher RSS leak watch
# ---------------------------------------------------------------------------
if [ "${DO_X4:-0}" = 1 ]; then
  echo "===== X4 ====="
  pgbench -i -s 50 postgres
  LPID=$(Q "SELECT pid FROM pg_stat_activity WHERE backend_type='autovacuum launcher'")
  ( while kill -0 "$LPID" 2>/dev/null; do
      echo "$(date +%s) launcher_VmRSS_kB=$(awk '/VmRSS/{print $2}' /proc/$LPID/status)"
      sleep 10
    done ) > "$HOME/rss.log" &
  MON=$!
  pgbench -T "${X4_SECS:-900}" -c 8 -j 4 postgres
  kill $MON 2>/dev/null
  echo "launcher RSS series -> $HOME/rss.log (leak = sustained monotonic growth)"
fi

echo "ALL DONE"

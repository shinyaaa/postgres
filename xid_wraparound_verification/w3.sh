#!/bin/bash
export PATH=$PGBIN:$PATH
LOGDIR=$PGDATA/log
# reset failsafe high so aw gets a full (slower) wraparound vacuum, not a fast failsafe bypass
psql -d postgres -c "ALTER SYSTEM SET vacuum_failsafe_age = 1600000000;"
psql -d postgres -c "SELECT pg_reload_conf();"
sleep 1
echo "failsafe now = $(psql -d postgres -Atc 'SHOW vacuum_failsafe_age;')"
psql -d postgres <<'EOF'
DROP TABLE IF EXISTS aw;
CREATE TABLE aw(a int, b text) WITH (autovacuum_vacuum_cost_delay=10, autovacuum_vacuum_cost_limit=300);
INSERT INTO aw SELECT g, md5(g::text) FROM generate_series(1,5000000) g;
CREATE INDEX ON aw(b);
DELETE FROM aw WHERE a % 3 = 0;
EOF
echo "aw age before consume: $(psql -d postgres -Atc "SELECT age(relfrozenxid) FROM pg_class WHERE relname='aw'")"
psql -d postgres -c "SELECT consume_xids(400000);" >/dev/null
echo "aw age after consume: $(psql -d postgres -Atc "SELECT age(relfrozenxid) FROM pg_class WHERE relname='aw'")"

echo "=== waiting for aw vacuum to appear in pg_stat_progress_vacuum ==="
appeared=""
for i in $(seq 1 120); do
  r=$(psql -d postgres -Atc "SELECT p.phase FROM pg_stat_progress_vacuum p JOIN pg_class c ON c.oid=p.relid WHERE c.relname='aw'")
  if [ -n "$r" ]; then echo "aw vacuum IN PROGRESS at ${i}s, phase=$r"; appeared="yes"; break; fi
  sleep 1
done
[ -z "$appeared" ] && echo "!!! aw vacuum NEVER appeared !!!"

echo "=== progress + worker flag snapshot ==="
psql -d postgres -c "SELECT pid, relid::regclass AS tbl, phase, heap_blks_scanned, heap_blks_total FROM pg_stat_progress_vacuum;"

echo "=== requesting ACCESS EXCLUSIVE lock on aw (timeout 90) ==="
t0=$(date +%s)
timeout 90 psql -d postgres -c "LOCK TABLE aw IN ACCESS EXCLUSIVE MODE;" 2>&1
lc=$?
t1=$(date +%s)
echo "LOCK exit=$lc waited=$((t1-t0))s (exit 124 = timed out still waiting)"

sleep 2
echo "=== 'canceling autovacuum task' lines mentioning aw (MUST be empty) ==="
grep "canceling autovacuum task" $LOGDIR/*.log | grep -i "aw" | tail
echo "=== any canceling autovacuum task at all ==="
grep -c "canceling autovacuum task" $LOGDIR/*.log 2>/dev/null | tail -3
echo "=== aw wraparound vacuum completion lines ==="
grep 'to prevent wraparound of table "postgres.public.aw"' $LOGDIR/*.log | tail

#!/bin/bash
export PATH=$PGBIN:$PATH
LOGDIR=$PGDATA/log
psql -d postgres -c "ALTER SYSTEM SET vacuum_failsafe_age = 300000;"
psql -d postgres -c "SELECT pg_reload_conf();"
sleep 1
echo "vacuum_failsafe_age now = $(psql -d postgres -Atc 'SHOW vacuum_failsafe_age;')"
psql -d postgres <<'EOF'
DROP TABLE IF EXISTS fs;
CREATE TABLE fs(a int, b text);
INSERT INTO fs SELECT g, md5(g::text) FROM generate_series(1,2000000) g;
CREATE INDEX ON fs(b);
DELETE FROM fs WHERE a % 2 = 0;
EOF
echo "=== fs relfrozenxid age before consume ==="
psql -d postgres -Atc "SELECT 'fs age='||age(relfrozenxid) FROM pg_class WHERE relname='fs';"
echo "=== consume 400000 xids ==="
psql -d postgres -c "SELECT consume_xids(400000);"
echo "=== fs relfrozenxid age after consume ==="
psql -d postgres -Atc "SELECT 'fs age='||age(relfrozenxid) FROM pg_class WHERE relname='fs';"
echo "=== monitor 180s for failsafe ==="
for i in $(seq 1 180); do
  if grep -qi "bypassing" $LOGDIR/*.log 2>/dev/null; then echo "FAILSAFE detected at ${i}s"; break; fi
  a=$(psql -d postgres -Atc "SELECT age(relfrozenxid) FROM pg_class WHERE relname='fs';")
  echo "${i}s: fs relfrozenxid age=$a"
  sleep 1
done
echo "=== failsafe log lines ==="
grep -i "failsafe\|bypassing" $LOGDIR/*.log | tail -20

#!/bin/bash
export PATH=$PGBIN:$PATH
LOG=$PGDATA/log
psql -d postgres <<'EOF'
CREATE TABLE frozen_target(a int) WITH (autovacuum_enabled = off);
INSERT INTO frozen_target SELECT generate_series(1,100000);
EOF
echo "=== ages before consume ==="
psql -d postgres -c "SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;"
echo "=== consuming 300000 xids ==="
psql -d postgres -c "SELECT consume_xids(300000);"
echo "=== ages after consume ==="
psql -d postgres -c "SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;"
echo "=== monitoring up to 300s ==="
for i in $(seq 1 300); do
  a=$(psql -d postgres -Atc "SELECT max(age(datfrozenxid)) FROM pg_database")
  echo "$i sec: max age=$a"
  if [ "$a" -lt 200000 ]; then echo ADVANCED; break; fi
  sleep 1
done
echo "=== frozen_target relfrozenxid age ==="
psql -d postgres -c "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname='frozen_target';"
echo "=== wraparound/aggressive log lines ==="
grep -E "wraparound|aggressive" $LOG/*.log | tail -30

#!/bin/bash
export PATH=$PGBIN:$PATH
psql -d postgres <<'EOF'
DROP TABLE IF EXISTS big2;
CREATE TABLE big2(a int, b text) WITH (autovacuum_vacuum_cost_delay=2, autovacuum_vacuum_cost_limit=150);
INSERT INTO big2 SELECT g, md5(g::text) FROM generate_series(1,3000000) g;
EOF
echo "big2 fresh unfrozen; relfrozenxid age before consume = $(psql -d postgres -Atc "SELECT age(relfrozenxid) FROM pg_class WHERE relname='big2'")"
echo "=== consume 10,000,000 xids ==="
psql -d postgres -c "SELECT consume_xids(10000000);" >/dev/null
echo "PEAK big2 age=$(psql -d postgres -Atc "SELECT age(relfrozenxid) FROM pg_class WHERE relname='big2'") maxdb age=$(psql -d postgres -Atc "SELECT max(age(datfrozenxid)) FROM pg_database")"
echo "=== monitor descent up to 300s ==="
prev=""
for i in $(seq 1 300); do
  b=$(psql -d postgres -Atc "SELECT age(relfrozenxid) FROM pg_class WHERE relname='big2'")
  d=$(psql -d postgres -Atc "SELECT max(age(datfrozenxid)) FROM pg_database")
  line="${i}s: big2_age=$b maxdb_age=$d"
  if [ "$b" != "$prev" ]; then echo "$line"; fi
  prev=$b
  if [ "$b" -lt 200000 ] && [ "$d" -lt 200000 ]; then echo "RECOVERED at ${i}s: big2_age=$b maxdb_age=$d"; break; fi
  sleep 1
done
echo "=== big2 wraparound-vacuum freeze record ==="
grep -A6 'wraparound of table "postgres.public.big2"' $PGDATA/log/*.log | grep -E 'wraparound of table .postgres.public.big2|frozen:|scanned' | tail -10
echo "=== TRAP/PANIC scan ==="
cat $PGDATA/log/*.log | grep -cE 'TRAP:|PANIC|terminated by signal'

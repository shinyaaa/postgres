#!/bin/bash
export PATH=$PGBIN:$PATH
# remove aw throttle so its wraparound vacuum is fast (global cost_delay=0)
psql -d postgres -c "ALTER TABLE aw RESET (autovacuum_vacuum_cost_delay, autovacuum_vacuum_cost_limit);"
echo "max age before big consume: $(psql -d postgres -Atc 'SELECT max(age(datfrozenxid)) FROM pg_database')"
echo "=== consume 10,000,000 xids to push age ~10M ==="
psql -d postgres -c "SELECT consume_xids(10000000);"
peak=$(psql -d postgres -Atc "SELECT max(age(datfrozenxid)) FROM pg_database")
echo "PEAK max age right after consume = $peak"
echo "=== monitor up to 900s for recovery ==="
prev=$peak
for i in $(seq 1 900); do
  a=$(psql -d postgres -Atc "SELECT max(age(datfrozenxid)) FROM pg_database")
  if [ $((i % 5)) -eq 0 ] || [ "$a" != "$prev" ]; then echo "${i}s: max age=$a"; fi
  prev=$a
  if [ "$a" -lt 200000 ]; then echo "RECOVERED below freeze_max_age(200000) at ${i}s: age=$a"; break; fi
  sleep 1
done
echo "=== final per-database ages ==="
psql -d postgres -c "SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;"
echo "=== top relfrozenxid ages ==="
psql -d postgres -c "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relkind in ('r','t','m') ORDER BY 2 DESC LIMIT 10;"
echo "=== TRAP/PANIC scan ==="
cat $PGDATA/log/*.log | grep -cE 'TRAP:|PANIC|terminated by signal'

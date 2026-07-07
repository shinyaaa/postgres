#!/bin/bash
PSQL=/home/user/pgav/bin/psql
relid=$($PSQL -d postgres -Atc "SELECT 'cx'::regclass::oid")
echo "cx oid=$relid"
found=""
for i in $(seq 1 100); do
  row=$($PSQL -d postgres -Atc "SELECT pid||'|'||phase||'|'||heap_blks_scanned||'/'||heap_blks_total FROM pg_stat_progress_vacuum WHERE relid=$relid")
  if [ -n "$row" ]; then
    echo "[$(date +%H:%M:%S.%N)] vacuum active: $row"
    found=1
    wpid=$(echo "$row" | cut -d'|' -f1)
    break
  fi
  sleep 0.1
done
if [ -z "$found" ]; then echo "NEVER SAW cx VACUUM in progress view"; exit 2; fi
echo "worker pid=$wpid ; issuing ACCESS EXCLUSIVE LOCK with 60s timeout"
start=$(date +%s.%N)
timeout 60 $PSQL -d postgres -v ON_ERROR_STOP=0 -c "\timing on" -c "LOCK TABLE cx IN ACCESS EXCLUSIVE MODE; SELECT 1 AS got_lock;"
rc=$?
end=$(date +%s.%N)
echo "LOCK psql rc=$rc  elapsed=$(echo "$end - $start" | bc)s"

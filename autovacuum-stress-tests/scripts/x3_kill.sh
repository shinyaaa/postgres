#!/bin/bash
PSQL=/home/user/pgav/bin/psql
relid=$($PSQL -d postgres -Atc "SELECT 'cx'::regclass::oid")
# create fresh dead tuples to trigger throttled (slow) autovacuum
$PSQL -d postgres -c "DELETE FROM cx WHERE a % 8 = 3;" 
echo "triggered; polling for cx worker..."
wpid=""
for i in $(seq 1 150); do
  row=$($PSQL -d postgres -Atc "SELECT pid||'|'||phase||'|'||heap_blks_scanned||'/'||heap_blks_total FROM pg_stat_progress_vacuum WHERE relid=$relid")
  if [ -n "$row" ]; then echo "[$(date +%H:%M:%S)] vacuum: $row"; wpid=$(echo "$row"|cut -d'|' -f1); break; fi
  sleep 0.1
done
[ -z "$wpid" ] && { echo "no worker seen"; exit 2; }
echo "SIGKILL worker $wpid"
kill -9 "$wpid"
echo "killed at $(date +%H:%M:%S). worker cmdline was:"
cat /proc/$wpid/cmdline 2>/dev/null | tr '\0' ' '; echo

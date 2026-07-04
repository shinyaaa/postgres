#!/bin/bash
# Reset selectivity matrix driver.
source /home/claude/pgwork/env.sh
SNAPDIR=/home/claude/pgwork/snaps
mkdir -p $SNAPDIR

snap () { $PSQL -tAF'|' -f /home/claude/pgwork/mon.sql; }

# Fill everything first
$PSQL -q -f /home/claude/pgwork/fill.sql >/dev/null 2>&1
bash /home/claude/pgwork/genlock.sh

echo "=== Targets tested via pg_stat_reset_shared(<target>) ==="
for tgt in io wal bgwriter checkpointer slru lock archiver recovery_prefetch NULL; do
  # refill to keep counters non-zero
  $PSQL -q -f /home/claude/pgwork/fill.sql >/dev/null 2>&1
  bash /home/claude/pgwork/genlock.sh
  $PSQL -q -c "SELECT pg_stat_force_next_flush();" >/dev/null 2>&1
  before=$(snap)
  if [ "$tgt" = "NULL" ]; then
    $PSQL -q -c "SELECT pg_stat_reset_shared();" >/dev/null 2>&1
  else
    $PSQL -q -c "SELECT pg_stat_reset_shared('$tgt');" >/dev/null 2>&1
  fi
  sleep 0.2
  after=$(snap)
  echo "$before" > $SNAPDIR/before_$tgt.txt
  echo "$after"  > $SNAPDIR/after_$tgt.txt
  echo "----- target=$tgt -----"
  # Compare per view
  paste -d'#' <(echo "$before") <(echo "$after") | while IFS='#' read b a; do
    vb=$(echo "$b" | cut -d'|' -f1); tsb=$(echo "$b" | cut -d'|' -f2); valb=$(echo "$b" | cut -d'|' -f3)
    va=$(echo "$a" | cut -d'|' -f1); tsa=$(echo "$a" | cut -d'|' -f2); vala=$(echo "$a" | cut -d'|' -f3)
    ts_changed="ts_same"; [ "$tsb" != "$tsa" ] && ts_changed="TS_UPDATED"
    val_note="val:$valb->$vala"
    printf "  %-18s %-11s %s\n" "$vb" "$ts_changed" "$val_note"
  done
done

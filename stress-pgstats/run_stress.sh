#!/bin/bash
# Orchestrator. Usage: run_stress.sh <label> <duration_seconds> [loops]
# loops: comma list subset of a,b,c,d,e (default all). Used for bisection.
source /home/user/stress/env.sh
LABEL="${1:-full}"
DUR="${2:-120}"
LOOPS="${3:-a,b,c,d,e}"
PIDS_FILE="$LOGDIR/pids_${LABEL}.txt"
: > "$PIDS_FILE"

echo "=== run $LABEL dur=$DUR loops=$LOOPS at $(date -Is) ==="

# pgbench background OLTP load
$PGI/bin/pgbench -c 50 -j 4 -T "$DUR" postgres > "$LOGDIR/pgbench_${LABEL}.log" 2>&1 &
PGBENCH_PID=$!
echo "pgbench $PGBENCH_PID" >> "$PIDS_FILE"

# stat-perturbation loops
declare -A SC=( [a]=loop_a_reset.sh [b]=loop_b_views.sh [c]=loop_c_backendlock.sh [d]=loop_d_ddl.sh [e]=loop_e_advisory.sh [f]=loop_f_fastpath.sh )
IFS=',' read -ra WANT <<< "$LOOPS"
for L in "${WANT[@]}"; do
  s="${SC[$L]}"
  [ -z "$s" ] && continue
  bash "/home/user/stress/$s" &
  echo "loop_$L $!" >> "$PIDS_FILE"
done

# monitor (foreground for this run's duration)
bash /home/user/stress/monitor.sh "$LABEL" "$DUR"

# teardown: kill all loops, then wait pgbench
echo "--- stopping loops ---"
while read -r name pid; do
  if [ "$name" != "pgbench" ]; then
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
  fi
done < "$PIDS_FILE"
# kill any stragglers spawned by loops
pkill -f "loop_._" 2>/dev/null
wait "$PGBENCH_PID" 2>/dev/null
echo "=== run $LABEL done at $(date -Is) ==="
tail -3 "$LOGDIR/pgbench_${LABEL}.log"

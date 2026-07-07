#!/bin/bash
# profile_one.sh <case_name> <"UNLOGGED"|""> — perf-profile server-side COPY FROM (3 passes = 30M rows)
set -eu
CASE=$1
UNLOGGED=${2:-}
B=$HOME/pgsql/copy-wal-perf/work/tmp/perfbench
PGBIN=$HOME/pgsql/copy-wal-perf/inst-perf/bin
PSQL="$PGBIN/psql -h $B -p 54329 -d postgres -qX"

$PSQL -c "DROP TABLE IF EXISTS t_$CASE" -c "CREATE $UNLOGGED TABLE t_$CASE (a bigint, b bigint)"

# warmup: 3 passes (extends relation to full 30M-row size, creates WAL segments), then reset;
# CHECKPOINT recycles segments so the profiled run reuses them
for i in 1 2 3; do $PSQL -c "COPY t_$CASE FROM '$B/narrow.csv'"; done
$PSQL -c "TRUNCATE t_$CASE" -c "CHECKPOINT"
sleep 1
$PSQL -c "SELECT pg_stat_reset_shared('wal')" > /dev/null

# controlled session via fifo so perf attaches before COPY starts
FIFO=$B/fifo_$CASE
rm -f "$FIFO"; mkfifo "$FIFO"
$PSQL -f "$FIFO" > "$B/session_$CASE.out" 2>&1 &
PSQL_PID=$!
exec 3>"$FIFO"
echo "\\timing on" >&3
echo "SELECT 1;" >&3
sleep 0.5

BACKEND_PID=$($PSQL -tAc "SELECT pid FROM pg_stat_activity WHERE backend_type='client backend' AND pid <> pg_backend_pid()" 3>&-)
[ -n "$BACKEND_PID" ] || { echo "ERROR: no backend pid"; exit 1; }

# 3>&- : do NOT leak the fifo write end into perf, or psql never sees EOF
perf record -g --call-graph fp -F 3989 -o "$B/perf_$CASE.data" -p "$BACKEND_PID" 2> "$B/perf_$CASE.err" 3>&- &
PERF_PID=$!
sleep 0.5

for i in 1 2 3; do echo "COPY t_$CASE FROM '$B/narrow.csv';" >&3; done
exec 3>&-                      # EOF -> psql runs COPYs, exits -> perf exits too
wait $PSQL_PID
wait $PERF_PID || true
echo "CASE=$CASE"
grep "^Time:" "$B/session_$CASE.out"
echo "ROWS=$($PSQL -tAc "SELECT count(*) FROM t_$CASE")"
echo "WALSTATS=$($PSQL -tAc "SELECT wal_records||' records, '||wal_fpi||' fpi, '||wal_bytes||' bytes' FROM pg_stat_wal")"
grep -o "[0-9]* samples" "$B/perf_$CASE.err" || tail -2 "$B/perf_$CASE.err"
rm -f "$FIFO"

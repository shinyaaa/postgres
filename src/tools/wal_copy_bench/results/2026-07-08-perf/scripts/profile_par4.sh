#!/bin/bash
# profile_par4.sh — perf-profile 4 concurrent COPY FROM backends (one table each, 10M rows each)
set -eu
B=$HOME/pgsql/copy-wal-perf/work/tmp/perfbench
PGBIN=$HOME/pgsql/copy-wal-perf/inst-perf/bin
PSQL="$PGBIN/psql -h $B -p 54329 -d postgres -qX"

for j in 1 2 3 4; do
  $PSQL -c "DROP TABLE IF EXISTS t_par$j" -c "CREATE TABLE t_par$j (a bigint, b bigint)"
done
# warmup: load all 4 concurrently once (extends relations, creates WAL segments)
for j in 1 2 3 4; do $PSQL -c "COPY t_par$j FROM '$B/narrow.csv'" & done
wait
$PSQL -c "TRUNCATE t_par1, t_par2, t_par3, t_par4" -c "CHECKPOINT"
sleep 1
$PSQL -c "SELECT pg_stat_reset_shared('wal')" > /dev/null

PIDS=""
for j in 1 2 3 4; do
  FIFO=$B/fifo_par$j
  rm -f "$FIFO"; mkfifo "$FIFO"
  $PSQL -f "$FIFO" > "$B/session_par$j.out" 2>&1 &
  eval "PSQL_PID$j=\$!"
  eval "exec $((j+4))>\$FIFO"
  echo "\\timing on" >&$((j+4))
  echo "SELECT 1;" >&$((j+4))
done
sleep 1

PIDS=$($PSQL -tAc "SELECT string_agg(pid::text, ',') FROM pg_stat_activity WHERE backend_type='client backend' AND pid <> pg_backend_pid()" 5>&- 6>&- 7>&- 8>&-)
NPIDS=$(echo "$PIDS" | tr ',' '\n' | wc -l)
[ "$NPIDS" = 4 ] || { echo "ERROR: expected 4 backends, got $NPIDS ($PIDS)"; exit 1; }
echo "backends: $PIDS"

perf record -g --call-graph fp -F 3989 -o "$B/perf_par4.data" -p "$PIDS" 2> "$B/perf_par4.err" 5>&- 6>&- 7>&- 8>&- &
PERF_PID=$!
sleep 0.5

START=$(date +%s%3N)
for j in 1 2 3 4; do echo "COPY t_par$j FROM '$B/narrow.csv';" >&$((j+4)); done
for j in 1 2 3 4; do eval "exec $((j+4))>&-"; done
for j in 1 2 3 4; do eval "wait \$PSQL_PID$j"; done
END=$(date +%s%3N)
wait $PERF_PID || true
echo "WALL_MS=$((END-START))"
for j in 1 2 3 4; do echo "job$j: $(grep '^Time:' $B/session_par$j.out | tail -1)"; done
echo "ROWS=$($PSQL -tAc "SELECT (SELECT count(*) FROM t_par1)+(SELECT count(*) FROM t_par2)+(SELECT count(*) FROM t_par3)+(SELECT count(*) FROM t_par4)")"
echo "WALSTATS=$($PSQL -tAc "SELECT wal_records||' records, '||wal_fpi||' fpi, '||wal_bytes||' bytes, buffers_full='||wal_buffers_full FROM pg_stat_wal")"
grep -o "[0-9]* samples" "$B/perf_par4.err" || tail -2 "$B/perf_par4.err"
rm -f $B/fifo_par?

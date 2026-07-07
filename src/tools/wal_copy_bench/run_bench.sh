#!/usr/bin/env bash
#
# run_bench.sh - Phase 0 measurement harness for COPY FROM WAL bottleneck
#
# Runs COPY FROM load benchmarks over a matrix of conditions and collects,
# per case:
#   - wall-clock time, rows/s, MB/s
#   - pg_stat_wal deltas (wal_records, wal_fpi, wal_bytes, wal_fpi_bytes,
#     wal_buffers_full)
#   - pg_stat_io (object='wal') deltas (writes, write_time, fsyncs, fsync_time)
#   - pg_waldump --stats / --stats=record breakdown for the exact LSN range
#   - wait-event sampling of the loading backends (poor man's profiler),
#     to split time between CPU, WALInsert lock waits, WAL write/sync, etc.
#
# The goal is to answer: is COPY FROM WAL overhead dominated by
#   (a) WAL byte volume (write/fsync bound),
#   (b) per-record overhead (XLogInsert CPU + WALInsert lock contention), or
#   (c) something else (extension locks, buffer management, parsing).
#
# Usage:
#   PGBIN=/path/to/pg/bin ./run_bench.sh [output_dir]
#
# Tunables (environment):
#   PGBIN         bin directory of a built postgres (default: pg_config on PATH)
#   BENCH_ROOT    scratch directory for cluster + data (default: /tmp/wal_copy_bench)
#   SCALE_NARROW  rows for the narrow table        (default: 5000000)
#   SCALE_WIDE    rows for the wide (~1KB) table   (default: 300000)
#   MAX_JOBS      max parallel COPY sessions, data is pre-split into this many
#                 chunks (default: 4)
#   FSYNC         fsync setting for the cluster (default: on)
#   SAMPLE_SEC    wait-event sampling interval (default: 0.05)
#   CASES_FILE    file with case definitions to override the built-in matrix
#
# Case definition format (one per line, '#' comments allowed):
#   name|wal_level|mode|wal_compression|width|jobs[|wal_buffers[|images]]
#     wal_level:  minimal | replica | logical
#     mode:       existing      COPY into a pre-committed regular table
#                 unlogged      COPY into a pre-committed UNLOGGED table (no-WAL
#                               upper bound with identical executor/buffer path)
#                 newrel        BEGIN; CREATE TABLE; COPY; COMMIT (WAL-skip
#                               eligible under wal_level=minimal)
#                 newrel_freeze same as newrel but COPY (FREEZE)
#     wal_compression: off | pglz | lz4 | zstd
#     width:      narrow (2x bigint) | wide (bigint + 1000-char text)
#     jobs:       number of concurrent COPY sessions (<= MAX_JOBS)
#     wal_buffers: optional, defaults to 16MB (the auto-tuned cap)
#     images:     optional on|off (default off); sets the Phase 2 prototype
#                 GUC debug_multi_insert_page_images (needs a patched build;
#                 cases are skipped gracefully on an unpatched server)

set -euo pipefail

PGBIN=${PGBIN:-$(dirname "$(command -v pg_config)")}
BENCH_ROOT=${BENCH_ROOT:-/tmp/wal_copy_bench}
SCALE_NARROW=${SCALE_NARROW:-5000000}
SCALE_WIDE=${SCALE_WIDE:-300000}
MAX_JOBS=${MAX_JOBS:-4}
FSYNC=${FSYNC:-on}
SAMPLE_SEC=${SAMPLE_SEC:-0.05}

OUTDIR=${1:-$BENCH_ROOT/results/$(date +%Y%m%d_%H%M%S)}
PGDATA=$BENCH_ROOT/data
DATADIR=$BENCH_ROOT/loaddata
PGPORT=${PGPORT:-54329}
PGDATABASE=postgres
export PGPORT PGDATABASE
export PGHOST=$BENCH_ROOT   # unix socket only

PSQL="$PGBIN/psql -X -q"
export PGOPTIONS="-c client_min_messages=warning"

mkdir -p "$OUTDIR" "$DATADIR"

log()
{
	echo "[$(date +%H:%M:%S)] $*"
}

# ---------------------------------------------------------------- data files
#
# Data is generated once, pre-split into MAX_JOBS chunk files per width so
# that jobs=1 and jobs=N cases load the exact same total rows.
gen_data()
{
	local width=$1 total=$2 per_chunk chunk

	per_chunk=$((total / MAX_JOBS))
	for ((chunk = 0; chunk < MAX_JOBS; chunk++))
	do
		local f=$DATADIR/$width.$chunk.dat

		if [ -s "$f" ]; then
			continue
		fi
		log "generating $f ($per_chunk rows)"
		if [ "$width" = narrow ]; then
			awk -v n=$per_chunk -v seed=$chunk 'BEGIN {
				for (i = 1; i <= n; i++)
					printf "%d\t%d\n", seed * n + i, (seed * n + i) * 17 % 1000000007
			}' > "$f"
		else
			awk -v n=$per_chunk -v seed=$chunk 'BEGIN {
				base = "";
				for (i = 0; i < 64; i++)
					base = base sprintf("%015d-", i * 48271 % 99991);
				for (i = 1; i <= n; i++) {
					id = seed * n + i;
					printf "%d\t%d-%s\n", id, id, substr(base, (id % 24) + 1, 985)
				}
			}' > "$f"
		fi
	done
}

# ------------------------------------------------------------ cluster control
server_stop()
{
	if [ -f "$PGDATA/postmaster.pid" ]; then
		"$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop > /dev/null
	fi
}

server_start_for_case()
{
	local wal_level=$1 wal_compression=$2 wal_buffers=${3:-16MB} images=${4:-off}

	cat > "$PGDATA/bench_case.conf" <<-EOF
		wal_level = $wal_level
		wal_compression = $wal_compression
		wal_buffers = $wal_buffers
	EOF
	if [ "$images" = on ]; then
		echo "debug_multi_insert_page_images = on" >> "$PGDATA/bench_case.conf"
	fi
	"$PGBIN/pg_ctl" -D "$PGDATA" -w -l "$OUTDIR/server.log" start > /dev/null
}

# Pre-allocate WAL segments by running the largest load once, untimed.
# Without this, the first case pays for zero-filling fresh 16MB segments
# (IO:WalInitWrite) that every later case gets back recycled.
warmup()
{
	local c

	log "warmup: pre-allocating WAL segments (untimed wide load)"
	server_start_for_case replica off
	ddl_for_width wide warmup_tbl | $PSQL > /dev/null
	for ((c = 0; c < MAX_JOBS; c++))
	do
		$PSQL -c "COPY warmup_tbl FROM '$DATADIR/wide.$c.dat';" > /dev/null
	done
	$PSQL -c "DROP TABLE warmup_tbl; CHECKPOINT;" > /dev/null
}

init_cluster()
{
	server_stop
	rm -rf "$PGDATA"
	"$PGBIN/initdb" -D "$PGDATA" -N > "$OUTDIR/initdb.log" 2>&1
	cat >> "$PGDATA/postgresql.conf" <<-EOF
		unix_socket_directories = '$BENCH_ROOT'
		listen_addresses = ''
		port = $PGPORT
		shared_buffers = 2GB
		max_wal_size = 16GB
		min_wal_size = 1GB
		checkpoint_timeout = 30min
		autovacuum = off
		fsync = $FSYNC
		track_wal_io_timing = on
		track_io_timing = on
		max_wal_senders = 0
		max_connections = 50
		log_checkpoints = on
		include 'bench_case.conf'
	EOF
	echo "wal_level = replica" > "$PGDATA/bench_case.conf"
	echo "wal_compression = off" >> "$PGDATA/bench_case.conf"
}

# --------------------------------------------------------------- case runner
ddl_for_width()
{
	local width=$1 table=$2 unlogged=${3:-}

	if [ "$width" = narrow ]; then
		echo "CREATE $unlogged TABLE $table(a bigint, b bigint);"
	else
		echo "CREATE $unlogged TABLE $table(id bigint, payload text);"
	fi
}

# Build the SQL script one job executes.  Each job loads chunk files
# [start, end) of its width, in a single transaction.
job_sql()
{
	local mode=$1 width=$2 job=$3 jobs=$4 table freeze="" c

	echo "SET synchronous_commit = on;"
	echo "BEGIN;"
	case $mode in
		existing|unlogged)
			table=bench_tbl
			;;
		newrel|newrel_freeze)
			table=bench_tbl_j$job
			ddl_for_width "$width" "$table"
			[ "$mode" = newrel_freeze ] && freeze=" (FREEZE)"
			;;
	esac
	# distribute MAX_JOBS chunks across the actual number of jobs
	for ((c = 0; c < MAX_JOBS; c++))
	do
		if [ $((c % jobs)) -eq "$job" ]; then
			echo "COPY $table FROM '$DATADIR/$width.$c.dat'$freeze;"
		fi
	done
	echo "COMMIT;"
}

run_case()
{
	local name=$1 wal_level=$2 mode=$3 compression=$4 width=$5 jobs=$6
	local wal_buffers=${7:-16MB} images=${8:-off}
	local detail=$OUTDIR/$name expected_rows total_rows actual_rows
	local start_lsn end_lsn t0 t1 elapsed sampler_pid j

	mkdir -p "$detail"
	log "=== case $name (wal_level=$wal_level mode=$mode compression=$compression width=$width jobs=$jobs wal_buffers=$wal_buffers images=$images)"

	server_stop
	if ! server_start_for_case "$wal_level" "$compression" "$wal_buffers" "$images"
	then
		log "    SKIPPED: server failed to start (unsupported wal_compression or GUC on this build?)"
		rm -f "$PGDATA/bench_case.conf.bad"
		mv "$PGDATA/bench_case.conf" "$PGDATA/bench_case.conf.bad" 2> /dev/null || true
		echo "wal_level = replica" > "$PGDATA/bench_case.conf"
		echo "wal_compression = off" >> "$PGDATA/bench_case.conf"
		return 0
	fi

	# fresh state
	$PSQL -c "DROP TABLE IF EXISTS bench_tbl;" > /dev/null
	for ((j = 0; j < MAX_JOBS; j++))
	do
		$PSQL -c "DROP TABLE IF EXISTS bench_tbl_j$j;" > /dev/null
	done
	case $mode in
		existing) ddl_for_width "$width" bench_tbl | $PSQL > /dev/null ;;
		unlogged) ddl_for_width "$width" bench_tbl UNLOGGED | $PSQL > /dev/null ;;
	esac
	$PSQL -c "CHECKPOINT;" > /dev/null
	$PSQL -c "SELECT pg_stat_reset_shared('wal'); SELECT pg_stat_reset_shared('io');" > /dev/null

	# wait-event sampler on the loading backends
	PGAPPNAME=walbench_sampler $PSQL -A -t > "$detail/wait_events.raw" 2> /dev/null <<-EOF &
		SELECT coalesce(wait_event_type || ':' || wait_event, 'CPU/Running')
		FROM pg_stat_activity
		WHERE application_name = 'walbench_load' AND state = 'active'
		\watch $SAMPLE_SEC
	EOF
	sampler_pid=$!

	start_lsn=$($PSQL -A -t -c "SELECT pg_current_wal_insert_lsn();")

	# launch the load jobs
	t0=$(date +%s.%N)
	local pids=()
	for ((j = 0; j < jobs; j++))
	do
		job_sql "$mode" "$width" "$j" "$jobs" > "$detail/job$j.sql"
		( tj0=$(date +%s.%N)
		  PGAPPNAME=walbench_load $PSQL -f "$detail/job$j.sql" > /dev/null
		  tj1=$(date +%s.%N)
		  echo "$tj0 $tj1" > "$detail/job$j.time" ) &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p"; done
	t1=$(date +%s.%N)
	elapsed=$(echo "$t1 $t0" | awk '{printf "%.3f", $1 - $2}')

	kill "$sampler_pid" 2> /dev/null || true
	wait "$sampler_pid" 2> /dev/null || true

	end_lsn=$($PSQL -A -t -c "SELECT pg_current_wal_insert_lsn();")

	# stats deltas (counters were reset just before the load)
	$PSQL -A -t -F'|' -c "SELECT wal_records, wal_fpi, wal_bytes, wal_fpi_bytes,
			wal_buffers_full FROM pg_stat_wal;" > "$detail/pg_stat_wal"
	$PSQL -A -t -F'|' -c "SELECT coalesce(sum(writes),0)::bigint,
			coalesce(sum(write_time),0)::numeric(20,1),
			coalesce(sum(fsyncs),0)::bigint,
			coalesce(sum(fsync_time),0)::numeric(20,1)
			FROM pg_stat_io WHERE object = 'wal';" > "$detail/pg_stat_io_wal"

	# row-count sanity check + heap size (outside the timed window)
	if [ "$width" = narrow ]; then
		expected_rows=$(( SCALE_NARROW / MAX_JOBS * MAX_JOBS ))
	else
		expected_rows=$(( SCALE_WIDE / MAX_JOBS * MAX_JOBS ))
	fi
	local size_sql count_sql
	case $mode in
		existing|unlogged)
			count_sql="SELECT count(*) FROM bench_tbl;"
			size_sql="SELECT pg_relation_size('bench_tbl');"
			;;
		newrel|newrel_freeze)
			count_sql="SELECT sum(c)::bigint FROM (
				SELECT count(*) AS c FROM bench_tbl_j0"
			size_sql="SELECT sum(s)::bigint FROM (
				SELECT pg_relation_size('bench_tbl_j0') AS s"
			for ((j = 1; j < jobs; j++))
			do
				count_sql+=" UNION ALL SELECT count(*) FROM bench_tbl_j$j"
				size_sql+=" UNION ALL SELECT pg_relation_size('bench_tbl_j$j')"
			done
			count_sql+=") t;"
			size_sql+=") t;"
			;;
	esac
	actual_rows=$($PSQL -A -t -c "$count_sql")
	local heap_bytes
	heap_bytes=$($PSQL -A -t -c "$size_sql")
	if [ "$actual_rows" != "$expected_rows" ]; then
		echo "WARNING: row count mismatch: expected $expected_rows got $actual_rows" | tee -a "$detail/WARN"
	fi

	# WAL record breakdown for the exact LSN range (before checkpoint recycles)
	"$PGBIN/pg_waldump" --stats -p "$PGDATA/pg_wal" \
		-s "$start_lsn" -e "$end_lsn" > "$detail/waldump_stats.txt" 2>&1 || true
	"$PGBIN/pg_waldump" --stats=record -p "$PGDATA/pg_wal" \
		-s "$start_lsn" -e "$end_lsn" > "$detail/waldump_stats_record.txt" 2>&1 || true

	# aggregate wait-event samples
	sort "$detail/wait_events.raw" | grep -v '^$' | uniq -c | sort -rn \
		> "$detail/wait_events.txt" || true

	# summary line
	local wal_records wal_fpi wal_bytes wal_fpi_bytes wal_buffers_full
	IFS='|' read -r wal_records wal_fpi wal_bytes wal_fpi_bytes wal_buffers_full \
		< "$detail/pg_stat_wal"
	local io_writes io_write_time io_fsyncs io_fsync_time
	IFS='|' read -r io_writes io_write_time io_fsyncs io_fsync_time \
		< "$detail/pg_stat_io_wal"

	awk -v OFS=',' \
		-v name="$name" -v wal_level="$wal_level" -v mode="$mode" \
		-v compression="$compression" -v width="$width" -v jobs="$jobs" \
		-v walbuf="$wal_buffers" -v images="$images" \
		-v rows="$actual_rows" -v elapsed="$elapsed" -v heap="$heap_bytes" \
		-v recs="$wal_records" -v fpi="$wal_fpi" -v bytes="$wal_bytes" \
		-v fpib="$wal_fpi_bytes" -v bfull="$wal_buffers_full" \
		-v iow="$io_writes" -v iowt="$io_write_time" \
		-v iof="$io_fsyncs" -v ioft="$io_fsync_time" \
		'BEGIN {
			rps = (elapsed > 0) ? rows / elapsed : 0;
			wal_mbps = (elapsed > 0) ? bytes / elapsed / 1048576 : 0;
			bpr = (rows > 0) ? bytes / rows : 0;
			ratio = (heap > 0) ? bytes / heap : 0;
			print name, wal_level, mode, compression, width, jobs, walbuf, images,
				rows, elapsed, int(rps),
				recs, fpi, bytes, fpib, sprintf("%.1f", bpr),
				sprintf("%.2f", ratio), sprintf("%.1f", wal_mbps),
				bfull, iow, iowt, iof, ioft, heap;
		}' >> "$OUTDIR/summary.csv"

	log "    elapsed=${elapsed}s rows=$actual_rows wal_bytes=$wal_bytes wal_records=$wal_records"
}

# -------------------------------------------------------------------- matrix
default_cases()
{
	cat <<-EOF
		# name|wal_level|mode|wal_compression|width|jobs
		# --- core baseline: where does the time go at wal_level=replica?
		narrow_replica_j1|replica|existing|off|narrow|1
		narrow_replica_j2|replica|existing|off|narrow|2
		narrow_replica_j4|replica|existing|off|narrow|4
		wide_replica_j1|replica|existing|off|wide|1
		wide_replica_j4|replica|existing|off|wide|4
		# --- no-WAL upper bound with identical executor/buffer path
		narrow_unlogged_j1|replica|unlogged|off|narrow|1
		narrow_unlogged_j4|replica|unlogged|off|narrow|4
		wide_unlogged_j1|replica|unlogged|off|wide|1
		# --- WAL-skip path (existing optimization; the other upper bound)
		narrow_minimal_newrel_j1|minimal|newrel|off|narrow|1
		wide_minimal_newrel_j1|minimal|newrel|off|wide|1
		narrow_minimal_existing_j1|minimal|existing|off|narrow|1
		# --- init-page/FREEZE variant (Phase 2 relevant)
		narrow_replica_freeze_j1|replica|newrel_freeze|off|narrow|1
		wide_replica_freeze_j1|replica|newrel_freeze|off|wide|1
		# --- compression and logical decoding overheads
		narrow_replica_lz4_j1|replica|existing|lz4|narrow|1
		narrow_logical_j1|logical|existing|off|narrow|1
		# --- wal_buffers sensitivity: is parallel COPY WALWrite-bound only
		#     because the default 16MB wal_buffers wraps?
		narrow_replica_j4_wb256|replica|existing|off|narrow|4|256MB
		wide_replica_j4_wb256|replica|existing|off|wide|4|256MB
		wide_replica_j1_wb256|replica|existing|off|wide|1|256MB
		# --- Phase 2 prototype: page-image multi-insert records.
		#     Controls are the corresponding cases above (images default off)
		#     plus the zstd-without-images case here.
		narrow_img_j1|replica|existing|off|narrow|1|16MB|on
		narrow_img_zstd_j1|replica|existing|zstd|narrow|1|16MB|on
		narrow_img_zstd_j4|replica|existing|zstd|narrow|4|16MB|on
		wide_img_j1|replica|existing|off|wide|1|16MB|on
		wide_zstd_j1|replica|existing|zstd|wide|1|16MB|off
		wide_img_zstd_j1|replica|existing|zstd|wide|1|16MB|on
		wide_img_zstd_j4|replica|existing|zstd|wide|4|16MB|on
		wide_img_zstd_j4_wb256|replica|existing|zstd|wide|4|256MB|on
	EOF
}

# --------------------------------------------------------------------- main
if [ ! -x "$PGBIN/postgres" ]; then
	echo "PGBIN=$PGBIN does not contain a postgres binary" >&2
	exit 1
fi

log "output: $OUTDIR"
{
	"$PGBIN/pg_config" --version
	echo "SCALE_NARROW=$SCALE_NARROW SCALE_WIDE=$SCALE_WIDE MAX_JOBS=$MAX_JOBS FSYNC=$FSYNC"
	uname -a
	grep -m1 'model name' /proc/cpuinfo || true
	echo "nproc=$(nproc)"
} > "$OUTDIR/meta.txt"

gen_data narrow "$SCALE_NARROW"
gen_data wide "$SCALE_WIDE"

trap server_stop EXIT
init_cluster
warmup

echo "name,wal_level,mode,compression,width,jobs,wal_buffers,images,rows,elapsed_s,rows_per_s,wal_records,wal_fpi,wal_bytes,wal_fpi_bytes,wal_bytes_per_row,wal_to_heap_ratio,wal_MB_per_s,wal_buffers_full,wal_io_writes,wal_io_write_time_ms,wal_io_fsyncs,wal_io_fsync_time_ms,heap_bytes" \
	> "$OUTDIR/summary.csv"

if [ -n "${CASES_FILE:-}" ]; then
	cases=$(grep -v '^\s*#' "$CASES_FILE" | grep -v '^\s*$')
else
	cases=$(default_cases | grep -v '^\s*#' | grep -v '^\s*$' | sed 's/^\s*//')
fi

while IFS='|' read -r name wal_level mode compression width jobs walbuf images
do
	run_case "$name" "$wal_level" "$mode" "$compression" "$width" "$jobs" \
		"${walbuf:-16MB}" "${images:-off}"
done <<< "$cases"

server_stop
trap - EXIT

log "done. summary: $OUTDIR/summary.csv"
if command -v column > /dev/null; then
	column -s, -t "$OUTDIR/summary.csv" | cut -c -200
else
	cat "$OUTDIR/summary.csv"
fi

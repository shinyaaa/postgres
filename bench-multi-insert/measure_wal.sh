#!/bin/bash
#
# measure_wal.sh
#
# Measure WAL volume produced by heap_multi_insert via COPY FROM, for tables
# of various row widths and various NULL densities.  Each scenario is run
# multiple times after a CHECKPOINT so the first and subsequent runs can be
# compared (FPI vs no-FPI behaviour).
#
# Usage:
#   PGBIN=/path/to/pg/bin PGDATA=/path/to/data ./measure_wal.sh [rows]
#
# Requires that PGBIN points at a built/installed PostgreSQL with psql,
# and PGDATA contains an initdb'd cluster the user can start.
#
# Output: TSV to stdout summarising bytes-of-WAL per scenario.

set -euo pipefail

PGBIN=${PGBIN:?must point at .../bin}
PGDATA=${PGDATA:?must point at a data directory}
PGPORT=${PGPORT:-55432}
DBNAME=${DBNAME:-bench}
ROWS=${1:-1000000}

PSQL="$PGBIN/psql -X -q -p $PGPORT -d $DBNAME"

start_pg() {
    "$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -c wal_compression=off -c full_page_writes=on -c max_wal_size=4GB -c checkpoint_timeout=1h -c synchronous_commit=off" -l /tmp/measure_wal.log -w start >/dev/null
}
stop_pg() {
    "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null
}

ensure_db() {
    "$PGBIN/psql" -X -q -p $PGPORT -d postgres -c "SELECT 1" >/dev/null 2>&1 || start_pg
    "$PGBIN/psql" -X -q -p $PGPORT -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DBNAME'" | grep -q 1 \
      || "$PGBIN/psql" -X -q -p $PGPORT -d postgres -c "CREATE DATABASE $DBNAME"
}

# $1 schema_sql  $2 csv_generator_sql  $3 label
run_scenario() {
    local schema_sql=$1
    local gen_sql=$2
    local label=$3

    $PSQL <<SQL >/dev/null
DROP TABLE IF EXISTS bench_t;
$schema_sql
SQL

    # Generate input file once
    local csv=/tmp/bench_${label}.csv
    $PSQL -c "COPY ($gen_sql LIMIT $ROWS) TO '$csv' (FORMAT csv)"

    for run in 1 2; do
        $PSQL -c "TRUNCATE bench_t" >/dev/null
        $PSQL -c "CHECKPOINT" >/dev/null
        local before
        before=$($PSQL -tAc "SELECT pg_current_wal_insert_lsn()::text")
        $PSQL -c "COPY bench_t FROM '$csv' (FORMAT csv)" >/dev/null
        local after
        after=$($PSQL -tAc "SELECT pg_current_wal_insert_lsn()::text")
        local diff
        diff=$($PSQL -tAc "SELECT pg_wal_lsn_diff('$after','$before')::bigint")
        local bytes_per_row=$(awk -v d=$diff -v r=$ROWS 'BEGIN { printf "%.2f", d/r }')
        printf '%s\trun=%d\twal_bytes=%s\tbytes_per_row=%s\trows=%s\n' \
               "$label" "$run" "$diff" "$bytes_per_row" "$ROWS"
    done

    rm -f "$csv"
}

ensure_db

echo "# heap_multi_insert WAL measurement"
echo "# rows=$ROWS  pg=$($PSQL -tAc 'SELECT version()')"
echo "# wal_compression=off  full_page_writes=on"
printf 'scenario\tinfo\twal_bytes\tbytes_per_row\trows\n'

# --- 1) very narrow: single int4 (4 bytes data + tuple header)
run_scenario \
    "CREATE UNLOGGED TABLE bench_t (a int);" \
    "SELECT g FROM generate_series(1,$ROWS) g" \
    "narrow_int4"

# --- 2) narrow with PK-like int8
run_scenario \
    "CREATE UNLOGGED TABLE bench_t (a bigint, b bigint);" \
    "SELECT g, g*2 FROM generate_series(1,$ROWS) g" \
    "narrow_2x_int8"

# --- 3) pgbench_accounts-like (~100B row)
run_scenario \
    "CREATE UNLOGGED TABLE bench_t (aid int, bid int, abalance int, filler char(84));" \
    "SELECT g, g%10, 0, repeat('x',84) FROM generate_series(1,$ROWS) g" \
    "pgbench_accounts_like"

# --- 4) medium width 300B
run_scenario \
    "CREATE UNLOGGED TABLE bench_t (a int, t text);" \
    "SELECT g, repeat('y',290) FROM generate_series(1,$ROWS) g" \
    "medium_300B"

# --- 5) wide 1KB
run_scenario \
    "CREATE UNLOGGED TABLE bench_t (a int, t text);" \
    "SELECT g, repeat('y',996) FROM generate_series(1,$ROWS) g" \
    "wide_1KB"

# --- 6) homogeneous: no NULLs everywhere, fixed-width
run_scenario \
    "CREATE UNLOGGED TABLE bench_t (a int NOT NULL, b int NOT NULL, c int NOT NULL);" \
    "SELECT g, g+1, g+2 FROM generate_series(1,$ROWS) g" \
    "homogeneous_3int"

# --- 7) heterogeneous: 50% NULLs in one column
run_scenario \
    "CREATE UNLOGGED TABLE bench_t (a int, b int, c int);" \
    "SELECT g, CASE WHEN g%2=0 THEN g+1 ELSE NULL END, g+2 FROM generate_series(1,$ROWS) g" \
    "heterogeneous_50pct_null"

# --- 8) COPY FREEZE on a fresh table (uses HEAP_INSERT_FROZEN path)
$PSQL <<SQL >/dev/null
DROP TABLE IF EXISTS bench_t;
CREATE TABLE bench_t (a int, b int, c int);
SQL
csv=/tmp/bench_freeze.csv
$PSQL -c "COPY (SELECT g, g+1, g+2 FROM generate_series(1,$ROWS) g) TO '$csv' (FORMAT csv)"
$PSQL -c "CHECKPOINT" >/dev/null
before=$($PSQL -tAc "SELECT pg_current_wal_insert_lsn()::text")
$PSQL -c "BEGIN; TRUNCATE bench_t; COPY bench_t FROM '$csv' (FORMAT csv, FREEZE); COMMIT;" >/dev/null
after=$($PSQL -tAc "SELECT pg_current_wal_insert_lsn()::text")
diff=$($PSQL -tAc "SELECT pg_wal_lsn_diff('$after','$before')::bigint")
bytes_per_row=$(awk -v d=$diff -v r=$ROWS 'BEGIN { printf "%.2f", d/r }')
printf 'copy_freeze_3int\trun=1\twal_bytes=%s\tbytes_per_row=%s\trows=%s\n' \
       "$diff" "$bytes_per_row" "$ROWS"
rm -f "$csv"

echo "# done"

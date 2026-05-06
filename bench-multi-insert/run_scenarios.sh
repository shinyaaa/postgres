#!/bin/bash
# Run a fixed COPY-FROM scenario set against a cluster and emit one TSV row per scenario.
# Usage: PSQL=<psql cmd>  ROWS=<rows> ./run_scenarios.sh <label>

set -euo pipefail
PSQL=${PSQL:?must set PSQL}
ROWS=${ROWS:-200000}
LABEL=${1:-unnamed}

$PSQL <<SQL >/dev/null
DROP TABLE IF EXISTS bench_a, bench_b, bench_c, bench_d, bench_e CASCADE;
CREATE TABLE bench_a (a int);
CREATE TABLE bench_b (a bigint, b bigint);
CREATE TABLE bench_c (aid int, bid int, abalance int, filler char(84));
CREATE TABLE bench_d (a int, t text);
CREATE TABLE bench_e (a int, b int, c int);
SQL

# Generate inputs (once per cluster).
$PSQL -c "COPY (SELECT g FROM generate_series(1,$ROWS) g) TO '/tmp/bench_a.csv' (FORMAT csv);" >/dev/null
$PSQL -c "COPY (SELECT g, g*2 FROM generate_series(1,$ROWS) g) TO '/tmp/bench_b.csv' (FORMAT csv);" >/dev/null
$PSQL -c "COPY (SELECT g, g%10, 0, repeat('x',84) FROM generate_series(1,$ROWS) g) TO '/tmp/bench_c.csv' (FORMAT csv);" >/dev/null
$PSQL -c "COPY (SELECT g, repeat('y',290) FROM generate_series(1,$ROWS) g) TO '/tmp/bench_d.csv' (FORMAT csv);" >/dev/null
$PSQL -c "COPY (SELECT g, g+1, g+2 FROM generate_series(1,$ROWS) g) TO '/tmp/bench_e.csv' (FORMAT csv);" >/dev/null

declare -A SCEN
SCEN[narrow_int4]=bench_a
SCEN[narrow_2x_int8]=bench_b
SCEN[pgbench_accounts_like]=bench_c
SCEN[medium_300B]=bench_d
SCEN[homogeneous_3int]=bench_e

for scen in narrow_int4 narrow_2x_int8 pgbench_accounts_like medium_300B homogeneous_3int; do
    tbl=${SCEN[$scen]}
    $PSQL -c "TRUNCATE $tbl; CHECKPOINT;" >/dev/null
    before=$($PSQL -tAc "SELECT pg_current_wal_insert_lsn()::text")
    $PSQL -c "COPY $tbl FROM '/tmp/${tbl}.csv' (FORMAT csv);" >/dev/null
    after=$($PSQL -tAc "SELECT pg_current_wal_insert_lsn()::text")
    diff=$($PSQL -tAc "SELECT pg_wal_lsn_diff('$after','$before')::bigint")
    printf "%s\t%s\t%s\t%s\n" "$LABEL" "$scen" "$diff" "$ROWS"
done

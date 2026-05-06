# heap_multi_insert WAL benchmarks

Scripts to measure the WAL volume produced by `heap_multi_insert` (i.e. the
`COPY FROM` / `CREATE TABLE AS` / `CTAS` / `INSERT ... SELECT` paths that go
through `table_multi_insert`).  These are intended to support the proposal
that aggregates several INIT_PAGE multi-insert WAL records into one record.

## Files

- `measure_wal.sh` — runs a fixed set of COPY-FROM scenarios against a
  cluster and prints WAL bytes per scenario.
- `breakdown_wal.sql` — uses `pg_waldump --stats=record` to break down the
  WAL volume by record type for a given LSN range.
- `compare_branches.sh` — convenience driver that builds two refs of the
  source tree (e.g. `master` vs the prototype branch), runs `measure_wal.sh`
  against each, and prints the delta.

## Quick start

```sh
# 1) Build current source and initdb a cluster
./configure --prefix=/tmp/pg-baseline/install --enable-debug CFLAGS=-O2
make -s -j install
/tmp/pg-baseline/install/bin/initdb -D /tmp/pg-baseline/data -U postgres -A trust

# 2) Measure baseline
PGBIN=/tmp/pg-baseline/install/bin \
PGDATA=/tmp/pg-baseline/data \
PGPORT=55432 \
./measure_wal.sh 1000000 > baseline.tsv

# 3) After applying the prototype patch, repeat with a different prefix and
#    diff the two TSVs.
```

`compare_branches.sh` automates steps 1-3 if both refs exist in the same
working tree:

```sh
SRC=/home/user/postgres ROWS=500000 \
./compare_branches.sh master claude/optimize-heap-multi-insert-wal-iXesX
```

## Scenarios

| label | row width | comment |
|---|---|---|
| `narrow_int4` | 4 B | best case for tuple-header overhead reduction |
| `narrow_2x_int8` | 16 B | small fixed-width tuple |
| `pgbench_accounts_like` | ~100 B | realistic narrow OLTP table |
| `medium_300B` | ~300 B | typical operational table |
| `wide_1KB` | ~1000 B | header overhead negligible |
| `homogeneous_3int` | NOT NULL | every tuple shares t_infomask |
| `heterogeneous_50pct_null` | mixed | half the rows have HEAP_HASNULL set |
| `copy_freeze_3int` | NOT NULL + FREEZE | exercises HEAP_INSERT_FROZEN path |

Each scenario is run twice: the first run after a `CHECKPOINT` (so first-touch
pages take FPIs in non-INIT cases), and a second run after a `TRUNCATE`
(typically all INIT_PAGE).  Reporting both runs makes the FPI vs no-FPI
behaviour visible.

## Reading the results

The script emits TSV with these columns:

```
scenario   info        wal_bytes  bytes_per_row  rows
```

`bytes_per_row` is the most useful summary: WAL volume normalised by row
count.  The expected effect of the prototype is:

- Narrow rows on INIT_PAGE pages: `bytes_per_row` drops noticeably (~5-7 B
  per record-overhead fraction × pages-per-record).
- Wide rows: very small change (record overhead is amortised over more data).
- FPI-dominated runs: little to no change (FPI byte count dwarfs everything).

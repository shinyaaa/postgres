# Measurement results: baseline vs prototype

Comparing `c06d1a4` (baseline) against the prototype branch
`claude/optimize-heap-multi-insert-wal-iXesX`.

Build: identical configure flags, both `-O2 --enable-cassert --without-icu`.
Runtime: `wal_compression=off`, `full_page_writes=on`,
`synchronous_commit=off`, `checkpoint_timeout=1h`, `max_wal_size=4GB`.

## COPY FROM, 300 000 rows per scenario

| scenario | row width | baseline (B) | proto (B) | delta | pct |
|---|---:|---:|---:|---:|---:|
| `narrow_int4`            | 4    | 3 805 392  | 3 805 232  |    -160 | **-0.00%** |
| `narrow_2x_int8`         | 16   | 7 418 552  | 7 278 528  | -140 024 | **-1.89%** |
| `pgbench_accounts_like`  | 100  | 32 253 152 | 32 011 160 | -241 992 | **-0.75%** |
| `medium_300B`            | 300  | 92 937 000 | 92 408 392 | -528 608 | **-0.57%** |
| `homogeneous_3int`       | 12   |  6 210 112 |  6 076 048 | -134 064 | **-2.16%** |

## Record-level breakdown via `pg_waldump --stats=record`

`COPY bench_inspect FROM PROGRAM 'seq -f "%g,1,2" 1 50000'`

### Baseline (3-int, 50 000 rows)

| Type                      |   N | Record bytes | FPI bytes | Combined  |
|---------------------------|----:|-------------:|----------:|----------:|
| XLOG/FPI_FOR_HINT         |   5 |          245 |    33 952 |    34 197 |
| Heap2/MULTI_INSERT        |  48 |      101 665 |         0 |   101 665 |
| Heap2/MULTI_INSERT+INIT   | 271 |      923 350 |         0 |   923 350 |
| **Total**                 | 326 |    1 025 318 |    33 952 | 1 059 270 |

### Prototype (3-int, 50 000 rows)

| Type                      |   N | Record bytes | FPI bytes | Combined  |
|---------------------------|----:|-------------:|----------:|----------:|
| XLOG/FPI_FOR_HINT         |   2 |           98 |     9 656 |     9 754 |
| Heap2/MULTI_INSERT+INIT   | 100 |    1 007 200 |         0 | 1 007 200 |
| **Total**                 | 104 |    1 007 356 |     9 656 | 1 017 012 |

## Observations

1. **Record count drops sharply, byte count drops modestly.**
   The prototype reduces `Heap2/MULTI_INSERT*` record count from
   319 (271 init + 48 non-init) to 100 — a 3.2x reduction — but the
   total Heap2 bytes only fall by ~17 800 (1.7%).  This is because the
   per-record overhead on a multi-insert is already small relative to the
   tuple data (~80 bytes per record amortised over several hundred tuples).

2. **Best case is still ~2%.**
   `homogeneous_3int` (12-byte tuples, 100% INIT_PAGE) shows -2.16% — the
   largest reduction we observed.  Wider tuples and tuples with mixed
   NULLs see less.  `narrow_int4` shows essentially zero improvement
   because per-record overhead is already amortised over hundreds of
   tuples per page.

3. **All non-init records are gone in the prototype.**
   The aggregation skips when bistate has a cached buffer, but the
   prototype does not update bistate after using `ExtendBufferedRelBy`,
   so the next `heap_multi_insert` call again sees an empty bistate and
   re-aggregates.  This is the reason the proto stats show 0
   non-init records.  As a side-effect the partially-filled last page
   of each batch is not tracked in the FSM and ends up under-utilised
   until VACUUM.  This is a real cost not reflected in the WAL number.

4. **FPI_FOR_HINT records also drop.**
   33 952 → 9 656 bytes.  This is incidental: fewer INIT-page records
   means fewer hint-bit pages, but it doesn't reflect WAL emission from
   `heap_multi_insert` itself.

## Implications for pgsql-hackers

The earlier estimate of 3-10% WAL reduction was too optimistic.  The
real number on COPY-driven workloads is closer to **0-2%**, dominated
by the fact that `MAX_BUFFERED_TUPLES = 1000` already amortises the
record overhead over many tuples.

Given:
- modest savings (~2% best case),
- non-trivial recovery code change,
- under-utilised tail-page side effect that would need to be fixed
  before this could be merged,

the proposal is **unlikely to be accepted in its current form**.
A revised proposal would need to either:
- combine with another reduction (e.g. homogeneous tuple-header sharing
  from "Plan 1") to reach a more compelling delta, or
- target a workload where multi-insert calls are smaller (catalog
  inserts, INSERT ... VALUES paths) where amortisation is weaker.

## Reproducing

```sh
# Baseline
git worktree add /tmp/pg-baseline/src c06d1a4
( cd /tmp/pg-baseline/src && ./configure --prefix=/tmp/pg-baseline/install \
    --enable-debug --enable-cassert --without-icu CFLAGS=-O2 && \
  make -s -j$(nproc) install )
sudo -u postgres /tmp/pg-baseline/install/bin/initdb -D /tmp/pg-baseline/data -U postgres -A trust
sudo -u postgres /tmp/pg-baseline/install/bin/pg_ctl -D /tmp/pg-baseline/data \
  -o "-p 55431 -c full_page_writes=on -c wal_compression=off -c synchronous_commit=off" \
  -l /tmp/pg-baseline/server.log -w start

# Prototype: same recipe but on this branch with prefix=/tmp/pg-proto/install,
# port 55432.

ROWS=300000 \
  PSQL='sudo -u postgres /tmp/pg-baseline/install/bin/psql -X -q -p 55431 -d postgres' \
  ./bench-multi-insert/run_scenarios.sh baseline > /tmp/results_baseline.tsv
ROWS=300000 \
  PSQL='sudo -u postgres /tmp/pg-proto/install/bin/psql -X -q -p 55432 -d postgres' \
  ./bench-multi-insert/run_scenarios.sh proto > /tmp/results_proto.tsv

awk -F'\t' '
NR==FNR { base[$2]=$3; rows[$2]=$4; next }
{ delta=$3-base[$2]; pct=delta/base[$2]*100;
  printf "%-25s baseline=%d proto=%d delta=%+d pct=%+.2f%%\n",
         $2, base[$2], $3, delta, pct }
' /tmp/results_baseline.tsv /tmp/results_proto.tsv
```

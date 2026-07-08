# wal_copy_bench — COPY FROM WAL bottleneck measurement harness (Phase 0)

This is the Phase 0 measurement harness for the "COPY FROM is WAL-bound"
investigation.  It benchmarks `COPY FROM` over a matrix of conditions and
collects enough instrumentation to decide *which* WAL cost dominates:

- **(a) WAL byte volume** — time spent in WAL write/fsync, `wal_bytes`,
  `pg_stat_io (object='wal')` write/fsync counts and timings.
- **(b) per-record overhead** — `wal_records` count, `pg_waldump --stats`
  record breakdown, `LWLock:WALInsert` / `LWLock:WALBufMapping` wait-event
  samples (contention on the 8 WAL insertion locks).
- **(c) everything else** — extension locks, buffer manager, input parsing
  (visible as `CPU/Running` and other wait events).

The answer determines which improvement phase to prioritize:

- byte-volume-bound → Phase 2 (page-image logging + compression leverage)
- record/lock-bound → Phase 1 (multi-page `XLOG_HEAP2_MULTI_INSERT` records)
  and/or Phase 3 (WAL insert lock scalability)

## Usage

```sh
# build postgres first (any recent master build; lz4 support recommended)
PGBIN=/path/to/install/bin ./run_bench.sh [output_dir]
```

Useful knobs (environment variables): `SCALE_NARROW` (default 5M rows),
`SCALE_WIDE` (default 300k rows of ~1KB; also used by the `rand` width,
a low-compressibility variant available via `CASES_FILE` — base64 of
/dev/urandom, for bounding the compression cases), `MAX_JOBS` (default 4),
`BENCH_ROOT` (scratch dir, default `/tmp/wal_copy_bench`), `FSYNC`,
`SAMPLE_SEC`, `CASES_FILE` (custom case matrix; format documented in the
script header).

The harness initdbs a throwaway cluster under `BENCH_ROOT` (unix socket
only, port 54329), generates load files once, and restarts the server
per case with the case's `wal_level` / `wal_compression`.

## Built-in case matrix

| group | cases | question answered |
|---|---|---|
| core baseline | `narrow/wide_replica_j{1,2,4}` | absolute COPY+WAL cost; how it scales with concurrent loaders |
| no-WAL bound | `*_unlogged_*` | identical executor/buffer path with zero WAL = upper bound of any WAL-side optimization |
| WAL-skip bound | `*_minimal_newrel_*` | the existing wal_level=minimal skip = what "no per-tuple WAL" buys end-to-end |
| FREEZE/init-page | `*_replica_freeze_*` | all-new-pages variant, closest existing shape to Phase 2's page-image logging |
| levers | `*_lz4_*`, `*_logical_*` | FPI compression effect; logical decoding tuple-data overhead |
| Phase 2 prototype | `*_img_*` | page-image multi-insert records (`debug_multi_insert_page_images=on`, needs patched build; skipped on unpatched servers) alone and combined with `wal_compression=zstd` |

Fixed server settings: `shared_buffers=2GB`, `max_wal_size=16GB`,
`checkpoint_timeout=30min` (no checkpoints mid-case → no FPI noise),
`autovacuum=off`, `track_wal_io_timing=on`.  Each case starts from a
CHECKPOINT and a `pg_stat_reset_shared('wal'/'io')`, and its exact LSN
range is analyzed with `pg_waldump --stats` before WAL can be recycled.

## Output

`summary.csv` — one line per case:
elapsed, rows/s, `wal_records`, `wal_fpi`, `wal_bytes`, WAL bytes/row,
WAL/heap ratio, WAL MB/s, `wal_buffers_full`, WAL io writes/fsyncs and
their times, heap bytes.

Per-case directory:
- `wait_events.txt` — aggregated wait-event histogram of the loading
  backends sampled every `SAMPLE_SEC` (default 50ms).  `CPU/Running`
  means no wait event, i.e. on-CPU (parsing, tuple forming, XLogInsert
  CPU, memcpy).
- `waldump_stats.txt`, `waldump_stats_record.txt` — record-type breakdown
  (count, record size, FPI size, combined share) for the case's LSN range.
- `job*.sql`, `job*.time` — exact per-job workload and timings.

## Interpreting results (cheat sheet)

- `Heap2/MULTI_INSERT` dominating `waldump_stats` combined size with
  ~50-80 bytes/record of header overhead → record-count reduction
  (Phase 1) saves CPU/locks but few bytes.
- `LWLock:WALInsert` share rising with jobs → insertion lock contention
  (Phase 1 batching or Phase 3 lock scaling).
- `IO:WALWrite` / `IO:WALSync` dominating and `wal_MB_per_s` near device
  throughput → byte-volume bound (Phase 2 + `wal_compression`).
- `wal_buffers_full` > 0 at scale → backends writing WAL synchronously
  because wal_buffers wrapped; retest with larger `wal_buffers`.
- gap between `*_replica_*` and `*_unlogged_*` elapsed = total WAL-side
  cost; gap to `*_minimal_newrel_*` = what WAL-skip achieves end-to-end.

## Caveats

- In throwaway/container environments the filesystem may absorb fsyncs
  quickly; relative shares (wait events, CPU vs IO) are more trustworthy
  than absolute MB/s.  Rerun on target-like storage before drawing
  conclusions about (a) vs (b) weighting.
- Wait-event sampling at 50ms is coarse for sub-second cases; scale row
  counts so cases run at least several seconds.

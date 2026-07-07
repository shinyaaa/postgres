# Phase 2 prototype, container measurement (functional + first numbers)

Same environment and scales as the 2026-07-07 baseline (4 vCPU container,
fast storage — absolute times are noisy and fsync-optimistic; byte counts
are exact).  Prototype: `debug_multi_insert_page_images=on` logs a forced
page image instead of per-tuple data for pages that a multi-insert fills
completely; images are compressed per `wal_compression`.

## WAL byte volume (the design target) — works as intended

| case | wal_bytes | B/row | vs control |
|---|---|---|---|
| narrow control | 245.1MB | 24.5 | — |
| narrow images, no compression | 409.4MB | 40.9 | **+67%** (predicted: full tuple headers + line pointers in image) |
| narrow images + zstd | 107.7MB | 10.8 | **−56%** |
| wide control | 612.1MB | 1020 | — |
| wide zstd, no images | 611.9MB | 1020 | ±0% — confirms per-tuple COPY data is never compressed today |
| wide images, no compression | 627.2MB | 1045 | +2.5% |
| wide images + zstd | 99.4MB | 166 | **−84%** (payload is semi-repetitive; real-data ratios will vary) |

## Elapsed (container storage — treat with caution)

- Parallel 4 jobs, wide: **2.09s → 1.73s (−17%)**, `wal_buffers_full`
  62775 → 0.  The byte reduction directly relieves the WALWrite-lock
  ceiling identified in Phase 0.
- Single session with zstd got *slower* (wide 2.7→4.7s): on storage this
  fast, single-threaded zstd costs more CPU than the bytes it saves.
  This is the expected trade and the reason the decisive run is on real
  storage (home0102), where Phase 0 showed WAL overhead is ~3/4 off-CPU
  write/fsync wait even at 1 job.
- Images without compression are elapsed-neutral here.

## Verification done before benchmarking

- Table contents byte-identical GUC on vs off (md5 over all rows).
- Crash recovery (immediate stop + WAL replay) with and without FREEZE;
  VM all-frozen page counts match the GUC-off control (1082/1120).
- Full `make check` (245 tests) passes with the GUC forced on.

## Next measurements (real storage)

1. Rerun the default matrix on home0102.  Expect the img+zstd cases to
   win at 1 job too if write/fsync wait dominates as in the perf run.
2. If lz4 can be installed there, add img+lz4 cases (likely better
   CPU/ratio trade than zstd for this use).
3. Compare `wal_io_write_time_ms`/`fsync_time_ms` and wait-event shares,
   not just elapsed.

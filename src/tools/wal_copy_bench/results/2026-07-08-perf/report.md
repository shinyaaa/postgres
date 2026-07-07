# perf profile of the XLogInsert path: Phase 1 go/no-go

Goal (from Phase 0 conclusion 2): split the WAL-induced cost of a
single-session narrow COPY into **(A) record-count-proportional** CPU vs
**(B) byte-proportional** CPU, to decide whether Phase 1 (multi-page
`XLOG_HEAP2_MULTI_INSERT` records, up to 32 pages/record = up to 1/32 the
record count) is worth building.

Method: `perf record -g` (cycles, user-only) on the COPY backend, logged
(`wal_level=replica`) vs UNLOGGED, 3×10M rows of (bigint, bigint) each,
same warmed cluster; the per-symbol **self-cycles difference**
logged−unlogged is the WAL-added CPU, decomposed by symbol.  Environment
and capture details: `meta.txt`; raw outputs: `*_flat.txt`,
`*_children.txt`, `*_callers_*.txt`.

## Headline: the WAL overhead is mostly not CPU at all

| case (30M rows) | wall | on-CPU | off-CPU |
|---|---|---|---|
| unlogged | 5.00 s | 4.94 s | 0.06 s |
| logged | 6.23 s | 5.25 s | 0.98 s |
| **WAL adds** | **+1.23 s (+25%)** | **+0.31 s** | **+0.92 s** |

On real storage (unlike the Phase 0 container), **~3/4 of the WAL
overhead is off-CPU wait** — WAL write/fsync latency absorbed by the
backend (isolated single pass: 33 backend fsyncs = 90 ms + 15 ms writes
per 10M rows; `wal_buffers_full=0`, so this is eviction/walwriter-overlap
flushing, not buffer wrap).  The XLogInsert-path CPU that Phase 1 targets
is only **~3.6% of total COPY CPU** (0.72 of 20.2 Gcycles), nowhere near
the ~30% runtime share Phase 0 attributed to on-CPU WAL work.

## WAL-added CPU, decomposed (logged − unlogged, self-cycles)

Total logged−unlogged difference: 757 Mcycles; 728 Mcycles (96%) is
directly attributable to WAL symbols below (rest is noise).

| bucket | component | Δ Mcycles | share of WAL CPU | unit cost |
|---|---|---:|---:|---|
| **A1 per-record fixed** | WAL insert locks (`LWLock*` diff, incl. `LWLockReleaseClearVar`) | 67 | 9% | — |
| | `XLogInsertRecord` self (reserve, hdr) | 24 | 3% | — |
| | `XLogInsert` self (assemble fixed part; `XLogRecordAssemble` is inlined here) | 12 | 2% | — |
| | `XLogBeginInsert`/`XLogRegister*` | 4 | 1% | — |
| | **A1 total** | **107** | **15%** | **~560 cycles/record** |
| **A2 per-tuple record build** | `heap_multi_insert` self diff (scratch packing, `xl_multi_insert_tuple` headers) | 284 | 39% | ~9.5 cycles/tuple |
| **B per-byte** | `pg_comp_crc32c_avx512` | 137 | 19% | 0.19 cycles/B |
| | `__memmove`/`memcpy@plt` diff (`CopyXLogRecordToWAL` copy into wal_buffers) | 132 | 18% | 0.18 cycles/B |
| | `AdvanceXLInsertBuffer` + `GetXLogBuffer` (per 8KB WAL page) | 68 | 9% | — |
| | **B total** | **337** | **46%** | **~0.46 cycles/B** |

(1 Mcycle ≈ 0.26 ms at the observed ~3.85GHz.)

## Go/no-go for Phase 1: **no-go**

By the letter of the decision rule, A = A1+A2 = 391 Mc (54%) vs
B = 337 Mc (46%) — "A is a (bare) majority".  But the rule's premise —
that A is what multi-page records eliminate — does not hold for A2:

- **Phase 1 only removes A1.**  A multi-page record still contains every
  tuple, so the per-tuple scratch packing and per-tuple record headers
  (A2, 39% of WAL CPU) are done exactly as today; only the ~560
  cycles/record fixed cost is divided by up to 32.
- A1 is **107 Mc ≈ 28 ms per 30M rows ≈ 0.5% of total COPY CPU** and
  ~2% of the end-to-end WAL overhead.  Even a perfect implementation is
  below run-to-run noise (pass times varied 1887–2222 ms).
- The dominant WAL cost (0.92 s off-CPU flush wait single-session; 27%
  off-CPU in the parallel capture, i.e. the `WALWrite` serialization from
  Phase 0) scales with **bytes**, and Phase 1 saves only the ~1.3% record
  header bytes.

## Parallel capture (4 backends, 1×10M rows each)

Wall 2.776 s; 8.08 CPU-s consumed of 11.10 available → **27% off-CPU**,
consistent with Phase 0's `LWLock:WALWrite` wall.  The user-space write
path is invisible CPU-wise (`XLogWrite` 0.05% self, `__libc_pwrite` 0.08%;
kernel time not sampled at `perf_event_paranoid=2`), and per-backend
insert-path shares match the single-session profile
(`XLogInsertRecord` 0.19%, CRC 0.73%, `LWLockAttemptLock` 0.52% — mild
insert-lock traffic increase, still no contention signal).  Nothing in
this capture changes the picture: the parallel ceiling is byte drain
through the single-threaded write path, not insertion CPU.

## Recommendation

1. **Drop Phase 1** (multi-page MULTI_INSERT records) as a performance
   measure.  Measured upper bound ≈ 0.5% single-session CPU, ~0% at the
   parallel ceiling.
2. **Proceed with Phase 2 (page-image logging + compression).**  Bytes
   are the binding constraint everywhere we have measured: B (46% of WAL
   CPU), the single-session off-CPU flush wait, and the parallel WALWrite
   ceiling all scale with WAL volume.  Page-image logging also happens to
   be the only design that can eliminate A2 (log the already-built page
   instead of re-packing tuples).  Note the trade: compression adds
   CPU (lz4 ≈ 0.5–1 cycles/B) to buy bytes — the right trade while the
   bottleneck is the write path, and exactly what these profiles let us
   model in advance.
3. Corrections to Phase 0's conclusion 2: "WAL adds ~29% runtime almost
   entirely as on-CPU work" does not hold on real storage — the on-CPU
   share of the WAL overhead here is ~25%, the rest is flush wait.  The
   Phase 0 wait-event sampling (80% CPU/Running overall) described the
   whole workload, not the WAL delta.

## Caveats

- `perf_event_paranoid=2`: user-space cycles only.  Kernel time (page
  cache copies in `pwrite`, fsync processing) is invisible; it is
  accounted indirectly via the on/off-CPU split and
  `pg_stat_io`/`track_wal_io_timing` numbers in `meta.txt`.
- `pg_stat_wal.wal_records` read in-session was inflated by the
  harness's own post-run verification queries; all record-shape numbers
  here come from `pg_waldump --stats` over exact LSN ranges (63,798
  records / 245.1 MB per 10M rows, 84.7% MULTI_INSERT+INIT with
  ntuples=185 — identical to the Phase 0 baseline shape).
- Frame-pointer unwinding drops the inlined
  `XLogInsert`→`XLogRecordAssemble` frame in some chains (CRC samples
  attach directly under `heap_multi_insert`); the decomposition therefore
  uses self-cycles diffs, which are unaffected by unwinding.
- Single machine (i5-1135G7, consumer SSD).  The off-CPU share moves
  with storage fsync latency; the CPU decomposition (A1/A2/B) should be
  hardware-stable since it is per-record/per-byte arithmetic.

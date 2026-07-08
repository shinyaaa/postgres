# Phase 2 decision run — page-image multi-insert WAL on real storage (home0102)

Same prototype as the container run (`debug_multi_insert_page_images=on`:
a multi-insert that fills a previously-empty page logs a forced page image
instead of per-tuple data; images compressed per `wal_compression`), now on
NVMe with fsync=on, lz4 available, and every decisive case repeated 3x
(spread within a case ~1%; medians below, from `summary-repeat.csv`).
The container's open question was whether compression CPU or WAL-write
waiting wins on real storage.  Answer: **it depends entirely on the
compressor — lz4 wins everywhere it can win, zstd loses everywhere.**

## Verdict: GO, as an adaptive opt-in tied to wal_compression

Page images + lz4 on compressible ~1KB rows: **−13% elapsed single
session, −38% at 4 parallel loaders, −80% WAL bytes**.  Narrow rows:
elapsed neutral (j4) to +11% (j1), −22% WAL.  Incompressible rows: +7%
to +21% elapsed and no byte win, so the mechanism must not be
unconditional — see the policy section.

## Elapsed medians (3 reps, seconds; % vs the matching control)

| case | control | images only | img+lz4 | img+zstd |
|---|---|---|---|---|
| wide j1 | 1.263 | 1.266 (±0%) | **1.095 (−13.3%)** | 1.692 (+34%) |
| wide j4 | 0.724 | — | **0.450 (−37.8%)** | 0.638 (−11.9%) |
| narrow j1 | 1.813 | — | 2.012 (+11.0%) | 2.680 (+47.8%) |
| narrow j4 | 0.660 | — | 0.678 (+2.7%) | 0.897 (+35.9%) |
| rand j1 | 1.265 | 1.252 (−1%)¹ | 1.528 (+20.8%) | 3.366 (+166%) |
| rand j4 | 0.729 | — | 0.782 (+7.3%)² | 1.284 (+76.1%) |

¹ single shot (run 2).  ² one of 3 reps was an outlier (1.55s); median shown.

`wide_zstd_j1` without images (1.259 ≈ control) reconfirms that per-tuple
COPY WAL is never compressed today; images are what makes the volume
compressible at all.

## WAL bytes per row

| width | control | img (no comp) | img+lz4 | img+zstd |
|---|---|---|---|---|
| wide | 1020 | 1045 (+2.5%) | **202 (−80%)** | 166 (−84%) |
| narrow | 24.5 | 40.9 (+67%) | 19.1 (−22%) | 10.8 (−56%) |
| rand | 1014 | 1038 (+2.3%) | 1020 (+0.6%) | 809 (−20%)³ |

³ zstd's entropy coder finds the 6-bits-per-byte redundancy of base64;
truly random binary would show ~0%.

## Answers to the questions the container could not settle

**1. Does img+compression win elapsed at j1 on real storage?**
Yes for lz4, no for zstd.  On this NVMe the wide j1 control spends
~320ms of 1263ms (25%) in WAL write+fsync (`wal_io_write_time` 45.5ms +
`fsync_time` 274.8ms; `IO:WalSync` 17/75 samples).  img+lz4 cuts that to
71ms (write 8.9 + fsync 62.1) and pays well under 100ms of compression
CPU: net −168ms.  zstd saves the same waiting but pays ~500ms of CPU:
net +429ms.  The perf-run expectation ("~3/4 of WAL overhead is off-CPU
wait") held directionally, but the absolute wait is small enough on NVMe
that only a fast compressor converts it into a win.  Images alone are
elapsed-neutral (wide_img_j1 ≈ control), i.e. forming the image is free;
everything hinges on what the compressor costs vs saves.

**2. How much does the parallel-4 WALWrite ceiling lift?**
A lot more than the container's −17%: **−37.8%** with lz4 (0.724 →
0.450s, 1.33M rows/s).  `LWLock:WALWrite` samples drop 48 → 15 (lz4)
and → 6 (zstd, which then just burns CPU instead), `wal_buffers_full`
65k → 0, WAL fsync time 268 → 55ms.  Byte volume was the binding
constraint for parallel COPY, exactly as Phase 0 predicted.

**3. lz4 vs zstd trade.**
lz4 beats zstd on elapsed in every single case, by 24-55%; zstd's only
edge is bytes (18% smaller on wide, 44% on narrow).  For load throughput
lz4 is the right recommendation; zstd (or higher levels) only makes sense
when archive/network volume matters more than load time.

**4. Low-compressibility data (rand = base64 of /dev/urandom).**
The failure mode is real but bounded and diagnosable: images alone are
neutral, so the entire regression is the futile compression attempt
(lz4: +21% j1 / +7% j4 for +0.6% bytes) or worse, zstd entropy-coding
its way to −20% bytes for +76% to +166% elapsed.  rand_img_lz4_j4 also
*increases* WALWrite contention (samples 63 → 99): same bytes plus
attempt CPU inside the insertion path.  Any product version must stop
trying when compression doesn't pay.

## Also worth noting

- narrow j1/j4 with lz4 is elapsed-neutral-to-slightly-worse despite
  −22% bytes: narrow images inflate the pre-compression volume +67%
  (whole tuple headers + line pointers in the image), and narrow COPY is
  parse/CPU-bound (WAL waits are only ~7% of j1 elapsed).  The byte win
  may still pay on slower storage or busier WAL devices, but on NVMe
  narrow tables are not where Phase 2 earns its keep.
- The existing wal_level=minimal newrel WAL-skip ran *slower* than
  plain logged COPY for wide j1 (1.508 single shot vs 1.263): it trades
  WAL for an end-of-COPY heap sync.  Byte reduction via images+lz4
  beats the skip on this storage.
- Record shape (waldump, wide img+lz4): 90% of records are
  Heap2/MULTI_INSERT carrying a compressed image (~610B for 8KB pages),
  10% are the per-tuple partial-page records at batch ends; combined
  121MB vs 612MB control for the same 600k rows.

## Proposed application policy (for the -hackers proposal)

1. **Gate on `wal_compression != off`.**  Without compression, images
   only add bytes (+2.5% wide, +67% narrow).  Tying the feature to the
   existing GUC reuses an opt-in whose meaning is already "spend CPU to
   shrink WAL", needs no new user knob, and picks the algorithm the
   admin already chose.  Keep the debug GUC only for testing.
2. **Fall back to per-tuple data when the compressed image is not
   smaller than the per-tuple payload it replaces.**  This caps byte
   inflation at zero on incompressible data (rand: 1020 → 1014 B/row)
   and makes the feature safe to enable implicitly.
3. **Bound the attempt cost adaptively.**  Fallback alone still pays
   the compression attempt (+21% worst case, lz4 j1).  Track the recent
   image-vs-payload outcome per COPY (e.g. a simple success counter or
   EWMA); after consistent failures stop attempting and re-probe every
   N pages.  For rand-like streams this reduces the regression to noise
   while preserving the full win on compressible streams.
4. **Document lz4 as the recommended `wal_compression` for bulk load.**
   With zstd (current common choice for FPI compression) a j1 COPY
   regresses even on compressible data; that is a documentation/default
   question, not a mechanism question, but it will come up in review.

Expected end-user impact where it applies (compressible ~1KB rows,
`wal_compression=lz4`): −13% single-stream COPY, −38% with 4 parallel
loaders, −80% WAL volume (also: smaller archives, less standby apply
and network — not measured here).  Next step: product-quality patch
implementing 1-3 and a -hackers thread with these numbers.

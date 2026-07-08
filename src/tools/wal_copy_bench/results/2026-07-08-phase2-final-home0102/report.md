# Phase 2 production patch — final numbers (home0102, NVMe, fsync=on)

Production form under test: `wal_multi_insert_page_images` (default on,
effective only with `wal_compression`), REGBUF_IMAGE_IF_SMALLER so an
image is adopted only when its compressed form is smaller than the
per-tuple data it replaces, and 3-consecutive-loss back-off with a
1-in-32 re-probe.  Correctness gates run on this exact build before
measuring: recovery TAP test 055 (4/4) and the full regression suite
under `wal_compression=lz4` + `wal_consistency_checking=heap2` (245/245).

Method as in the 2026-07-08-phase2-home0102 decision run: 3 repetitions
per case, interleaved; medians reported; controls pin the GUC off.

## Results table (for the -hackers mail)

COPY FROM into an existing logged table, wal_level=replica, NVMe,
fsync=on.  10M rows of 2x bigint ("narrow"), 600k rows of ~1kB
compressible text ("wide"), 600k rows of ~1kB incompressible base64
("rand").  j = concurrent COPY sessions.  Median of 3 runs; elapsed
spread within a case was <=1% (j1) / <=8% (j4).

| case                     | WAL bytes         | elapsed             |
|--------------------------|-------------------|---------------------|
| narrow j1, lz4           | −22.1%            | +13.2% (1.775 → 2.009 s) |
| narrow j4, lz4           | −22.2%            | +8.0%  (0.664 → 0.717 s) |
| wide j1, lz4             | −80.2%            | −11.9% (1.263 → 1.113 s) |
| wide j4, lz4             | −80.3%            | −38.0% (0.726 → 0.450 s) |
| rand j1, lz4             | −0.03%            | +0.4%  (1.271 → 1.276 s) |
| rand j4, lz4             | −0.03%            | −1.1%  (0.739 → 0.731 s) |
| wide j1, zstd            | −83.7%            | +35.2% (1.263 → 1.707 s) |
| wide j4, zstd            | −83.8%            | −13.2% (0.726 → 0.630 s) |

Supporting instrumentation (medians): wide j1 WAL fsync time 278 →
63 ms and write time 45 → 9 ms with lz4; wide j4 `LWLock:WALWrite`
wait-event samples 69 → 15 (3-rep sums, see wait_events/);
`wal_buffers_full` 68k → 0.

## Check 3: images=on + wal_compression=off is a strict no-op — PASS

The prototype inflated WAL +67% on narrow when imaging without
compression; the production policy must not attempt images at all
unless wal_compression is set.  Confirmed:

| case          | elapsed vs control | wal_bytes vs control | wal_fpi        |
|---------------|--------------------|----------------------|----------------|
| narrow_img_j1 | +0.3% (1.780 vs 1.775) | +0.0003%         | 18 (= control; all FPI_FOR_HINT) |
| wide_img_j1   | −0.1% (1.262 vs 1.263) | +0.0001%         | 27 (= control) |

pg_waldump for narrow_img_j1: Heap2 records carry zero FPI bytes; the
only FPIs in the range are the same XLOG/FPI_FOR_HINT records the
control has.

## Check 4: back-off residual on incompressible data — PASS

Target was <= +2% (the prototype paid +21% at j1).  Measured:
rand j1 +0.4%, rand j4 −1.1% — inside run-to-run noise.  pg_waldump
for rand_img_lz4_j1 shows 0 adopted images: total FPI in the LSN range
is 5935 bytes across 27 XLOG/FPI_FOR_HINT records (the control's same
27 hint FPIs, lz4-compressed), Heap2 FPI = 0.  The wait-event
histogram is shape-identical to the control.  The back-off suspends
attempts after the first 3 losses and every 32-page re-probe keeps
losing, so the residual cost is a handful of compression attempts per
COPY, not one per page.

## Assessment of default on

The only regression in the matrix is narrow + lz4: +13.2% at j1, +8.0%
at j4, in exchange for −22% WAL.  This is a real trade, not noise, and
it is the honest headline caveat for the proposal: narrow rows are
CPU-bound (WAL waits are ~7% of elapsed) and every image attempt wins,
so the compression CPU buys bytes the workload wasn't waiting on.
Points in favor of keeping the default on nonetheless:

- It only triggers when the admin has already set `wal_compression`,
  which is precisely the "spend CPU to shrink WAL" opt-in, and today
  that setting quietly fails to deliver any WAL reduction for bulk
  loads (wide j1 zstd-without-images was ±0% in the decision run).
- On the workloads bulk-load WAL volume actually hurts (wide rows,
  parallel loaders, WAL device saturation, standby/archive bandwidth)
  it is a large win: −38% elapsed and −80% bytes at wide j4.
- The worst case a user can hit by accident is bounded: −22% WAL for
  +8-13% elapsed on narrow tables, and ~0% on incompressible data
  thanks to the loss-based fallback + back-off.
- Anyone who dislikes the narrow-table trade has a one-GUC exit.

If reviewers judge the narrow j1 number too aggressive for a default,
the fallback position is default off with a strong documentation
recommendation for bulk loads; the mechanism is unchanged either way.
Recommend leading with the table above and stating the narrow numbers
explicitly rather than letting reviewers discover them.

zstd remains a poor fit for COPY-time compression (+35% at j1 despite
the best ratio); the docs note recommending lz4 stays.

## Delta vs the prototype decision run (same host, same scales)

Wins are unchanged (wide j1 −11.9% vs −13.3%, wide j4 −38.0% vs
−37.8%).  The two behavior changes both landed as designed: rand j1
went from +20.8% (forced attempts) to +0.4% (back-off), and
images-without-compression went from +67% bytes (forced imaging) to a
no-op (policy gate).  narrow_img_lz4_j4's median moved 0.678 → 0.717s;
its reps span 0.685-0.741 vs the control's 0.649-0.670, so the +8% is
real but the exact magnitude is the noisiest number here (j1, at
+13.2%, is tight: 2.005-2.010 vs 1.767-1.775).

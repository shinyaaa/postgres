# Phase 0 baseline: where does COPY FROM spend its WAL time?

Environment: 4 vCPU container, 15GB RAM, master @ 6d4ca6d, -O2 build,
`shared_buffers=2GB`, default `wal_buffers=16MB` unless stated, `fsync=on`
(container storage; fsync latency is optimistic — relative shares matter
more than absolute MB/s here).  Loads: narrow = 10M rows of (bigint,
bigint) ≈ 445MB heap / 245MB WAL; wide = 600k rows of (bigint, 1000-char
text) ≈ 705MB heap / 612MB WAL.  Full data: `summary.csv`,
`wait_events_all.txt`.

## Headline numbers

| case | elapsed | vs no-WAL bound | dominant wait profile |
|---|---|---|---|
| narrow replica j1 | 2.82s | unlogged 2.18s (**+29%**) | 80% CPU, 10% WalSync |
| narrow replica j4 | 1.35s | unlogged 0.74s (**+83%**) | **52% LWLock:WALWrite**, 30% CPU |
| wide replica j1 | 2.70s | unlogged 1.22s (**+121%**) | 45% CPU, **38% IO:WalSync** |
| wide replica j4 | 2.31s | — | **57% LWLock:WALWrite**, 21% CPU |
| narrow replica j4, wal_buffers=256MB | 1.24s (−8%) | `wal_buffers_full` 19790 → 0 | WALWrite still #1 (36%) |
| wide replica j4, wal_buffers=256MB | 1.95s (−15%) | `wal_buffers_full` 56877 → 0 | WALWrite still #1 (52%) |
| narrow minimal newrel (WAL-skip) j1 | 3.42s | **slower** than WAL-logged 2.82s | commit-time relation sync |
| narrow replica lz4 j1 | 3.08s | no byte change (FPI-only compression) | — |

Other data points: `wal_level=logical` +5% (j1); COPY FREEZE (all
INIT-page records) — same bytes, same elapsed as regular COPY; WAL
record-header overhead measured by `pg_waldump --stats=record` is
**~1.3% of WAL bytes** (63,803 records ≈ 50B header each vs 245MB
total; ~1.18 records per filled page — the extra 0.18 comes from the
1000-row copy.c flush boundary splitting pages across records).

## Conclusions for the improvement phases

1. **The parallel-load ceiling is the WAL *write* path, not the WAL
   *insert* path.**  `LWLock:WALInsert` (the 8 insertion locks, Phase 3's
   target) is essentially absent from every profile; `LWLock:WALWrite`
   dominates as soon as jobs ≥ 2.  Bigger `wal_buffers` eliminates the
   `wal_buffers_full` stalls and buys 8–15%, but the single-threaded
   WALWrite drain remains the ceiling (~200–300 MB/s here).
   → Phase 3 as originally scoped (NUM_XLOGINSERT_LOCKS) targets a
   non-bottleneck for this workload and should be dropped or re-scoped
   to the write/flush pipeline.
   → Byte-volume reduction (Phase 2) directly raises this ceiling too.

2. **Single-session narrow COPY is CPU-bound**, and WAL adds ~30%
   runtime almost entirely as on-CPU work (record assembly, memcpy into
   wal_buffers) — there is no lock contention and little IO wait to
   remove.  Phase 1 (multi-page records) attacks exactly this per-record
   CPU, but the byte-level record overhead is only ~1.3%, so gains are
   bounded by how much of the XLogInsert CPU path is per-record vs
   per-byte.  Profiling XLogRecordAssemble/CopyXLogRecordToWAL split is
   the next measurement before committing to Phase 1.

3. **Byte-heavy COPY is volume-bound** (wide j1: +121% vs unlogged,
   WalSync-dominated), and `wal_compression=lz4` does nothing for it
   because only FPIs are compressed — per-tuple COPY data is never
   compressed today.  Phase 2 (page-image logging, which makes the bulk
   data compressible) is the only lever that reduces bytes, and the wide
   profile shows bytes are the binding constraint wherever storage is
   slower than CPU.

4. **Surprise: the wal_level=minimal WAL-skip path was *slower* than
   WAL-logged COPY here** (3.42s vs 2.82s narrow; 3.26s vs 2.70s wide),
   because the commit-time relation sync serializes what the WAL path
   overlaps with the load.  On slow-fsync storage this will flip, but it
   shows the skip path has its own optimization headroom (e.g. syncing
   concurrently with the load).

## Revised phase priorities

- **Phase 2 (page-image logging + compression)**: promoted — it is the
  only byte-volume lever, and byte volume is the binding constraint for
  both wide single-session and all parallel loads.
- **Phase 1 (multi-page WAL records)**: still worthwhile for
  narrow/CPU-bound loads, but validate with an XLogInsert CPU profile
  first; expected win is CPU-path, not bytes.
- **Phase 3**: re-scope from insertion locks to the WALWrite/flush
  pipeline (group writes, larger writes, or async draining); document
  `wal_buffers` tuning as an immediate operational win for parallel COPY.

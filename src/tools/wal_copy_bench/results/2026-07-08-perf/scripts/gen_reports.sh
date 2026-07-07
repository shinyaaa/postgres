#!/bin/bash
# Generate perf report text outputs for the three captures.
set -eu
B=$HOME/pgsql/copy-wal-perf/work/tmp/perfbench
cd $B
mkdir -p out

for c in logged unlogged par4; do
  perf report --stdio --no-children -g none --percent-limit 0.03 -i perf_$c.data > out/${c}_flat.txt 2>/dev/null
  perf report --stdio --children -g none --percent-limit 0.2 -i perf_$c.data > out/${c}_children.txt 2>/dev/null
  perf report --header-only -i perf_$c.data 2>/dev/null | grep -E "cmdline|sample|event" > out/${c}_header.txt || true
done

# caller graphs for the WAL-relevant leaves (logged case)
for s in XLogInsertRecord pg_comp_crc32c_avx512 __memmove_evex_unaligned_erms GetXLogBuffer LWLockAttemptLock LWLockRelease LWLockReleaseClearVar memcpy@plt __memset_evex_unaligned_erms; do
  perf report --stdio --no-children -g graph,0.3,caller -S "$s" -i perf_logged.data > "out/logged_callers_$s.txt" 2>/dev/null || true
done
# same for par4, plus write-path symbols
for s in XLogInsertRecord pg_comp_crc32c_avx512 __memmove_evex_unaligned_erms XLogWrite XLogFlush LWLockAcquireOrWait; do
  perf report --stdio --no-children -g graph,0.3,caller -S "$s" -i perf_par4.data > "out/par4_callers_$s.txt" 2>/dev/null || true
done
ls -la out/ | head -30

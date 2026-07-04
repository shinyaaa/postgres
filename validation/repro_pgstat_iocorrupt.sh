#!/bin/bash
# Minimal reproducer: a single-byte flip in the persisted pgstat.stat IO-stats
# region is loaded WITHOUT value validation, tripping
# Assert(pgstat_bktype_io_stats_valid) -> SIGABRT -> cluster crash recovery.
#
# Requires: assert-enabled (--enable-cassert) build.
# Run as the (unprivileged) postgres OS user. Adjust BIN/PGDATA as needed.
set -u
BIN=/root/pgi/bin
PGDATA=/home/pg/pgdata
LOG=/home/pg/logs/pg.log
PSQL="$BIN/psql -X -d postgres -tA"
F=$PGDATA/pg_stat/pgstat.stat

# 0. Preconditions: server up with custom stats preloaded is NOT required; plain
#    server is enough since the poisoned counter is a *builtin* IO stat.
"$BIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 || "$BIN/pg_ctl" -D "$PGDATA" -l "$LOG" -w start

# 1. Produce a deterministic, non-empty stats file via a clean shutdown.
$PSQL -c 'SELECT pg_stat_reset()'          >/dev/null
$PSQL -c 'CHECKPOINT'                      >/dev/null   # give checkpointer real IO
$PSQL -c 'SELECT pg_stat_force_next_flush()' >/dev/null
"$BIN/pg_ctl" -D "$PGDATA" -w stop -m fast

# 2. Corrupt a 32-byte data run at the file midpoint. This lands inside the
#    fixed IO-stats block and is wide enough to guarantee that at least one
#    *untracked* per-backend-type IO counter becomes non-zero, regardless of
#    exact struct alignment. (A single-byte flip also works, but only when it
#    hits the high byte of an untracked counter, so it is layout-dependent.)
SZ=$(stat -c %s "$F"); MID=$((SZ/2))
echo "smearing 32x 0xFF at offset $MID of $SZ"
dd if=/dev/zero bs=1 count=32 2>/dev/null | tr '\0' '\377' \
  | dd of="$F" bs=1 seek="$MID" count=32 conv=notrunc 2>/dev/null

# 3. Start: the reader loads the poisoned counter with no warning...
: > "$LOG"
"$BIN/pg_ctl" -D "$PGDATA" -l "$LOG" -w start
echo "--- read-time log (expect NO corruption warning) ---"
grep -iE "corrupted|WARNING|could not" "$LOG" || echo "(none: poison loaded silently)"

# 4. ...then any access that runs the IO-stats validity assert aborts.
#    Use a FULL scan (count(*)) so every per-backend-type row is validated;
#    a LIMIT 1 may short-circuit before reaching the poisoned backend type.
echo "--- scanning pg_stat_io (expect SIGABRT / crash recovery) ---"
$PSQL -c 'SELECT count(*) FROM pg_stat_io' 2>&1 | head -3
sleep 1
grep -iE "terminated by signal 6|reinitializing|was not properly shut down" "$LOG" | head
ls -la "$PGDATA"/core 2>/dev/null && echo "CORE DUMPED -> crash confirmed"

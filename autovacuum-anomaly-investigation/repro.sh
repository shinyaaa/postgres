#!/bin/bash
# =============================================================================
# repro.sh -- reproduce the one execution-verified autovacuum-relevant anomaly
#             found while exploring PostgreSQL master.
#
# HEAD commit under test : 6d4ca6de97770cdaee18517dd2f8fe8f4ecee187
#                          ("psql: Fix \df tab completion for procedures", 20devel)
# configure options      : --prefix=$HOME/pgav --enable-debug --enable-cassert
#                          CFLAGS="-O0 -g3"
# Reproduction rate      : 3/3 (deterministic)
#
# WHAT THIS DEMONSTRATES
#   n_ins_since_vacuum (and n_mod_since_analyze) is NOT reliably reset to 0 by
#   VACUUM (resp. ANALYZE) when the VACUUM runs in the same backend immediately
#   after the DML, i.e. before that backend's pending cumulative-statistics
#   delta has been flushed to shared memory (deferred by PGSTAT_MIN_INTERVAL,
#   1s).  pgstat_report_vacuum() resets the shared counter to 0, then the
#   backend's still-pending "+N inserts" is flushed on top of it
#   (pgstat_relation.c: pgstat_relation_flush_cb, "tabentry->ins_since_vacuum
#   += lstats->counts.tuples_inserted"), so the counter ends at N instead of 0.
#   This is the input that drives autovacuum's insert-based triggering.
#
# CLASSIFICATION: PRE-EXISTING, NOT A MASTER REGRESSION.
#   The identical behaviour reproduces on stock PostgreSQL 16.13 (see
#   evidence/06_pg16_comparison.txt).  It is a long-standing consequence of
#   the deferred pgstat flush design, acknowledged in a nearby code comment.
#   It is included here because it is the ONLY reproducible behavioural
#   deviation surfaced by the exploration; all core autovacuum decision,
#   scoring, prioritization and anti-wraparound paths behaved correctly
#   (see report.md).
#
# EXIT STATUS: 1 if the anomaly is observed (counter not reset), 0 if not.
#
# USAGE: PGBIN=/opt/pgav/bin ./repro.sh
#        (must be run as a NON-root user; point PGBIN at the build's bin/)
# =============================================================================
set -u

PGBIN="${PGBIN:-$HOME/pgav/bin}"
PORT="${PORT:-55440}"
WORK="$(mktemp -d /tmp/av_repro.XXXXXX)"
DATA="$WORK/data"
export LD_LIBRARY_PATH="$(dirname "$PGBIN")/lib:${LD_LIBRARY_PATH:-}"

log() { echo "[repro] $*"; }
cleanup() { "$PGBIN/pg_ctl" -D "$DATA" -mimmediate -w stop >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

if [ "$(id -u)" = "0" ]; then
    echo "ERROR: PostgreSQL refuses to run as root. Re-run as a normal user." >&2
    exit 2
fi

log "initdb ($("$PGBIN/postgres" --version))"
"$PGBIN/initdb" -D "$DATA" -U postgres -A trust >/dev/null 2>&1 || { echo "initdb failed"; exit 2; }

cat >> "$DATA/postgresql.conf" <<EOF
port = $PORT
listen_addresses = '127.0.0.1'
unix_socket_directories = '$WORK'
autovacuum = off
EOF

"$PGBIN/pg_ctl" -D "$DATA" -l "$WORK/server.log" -w start >/dev/null 2>&1 || { echo "start failed"; cat "$WORK/server.log"; exit 2; }
PSQL() { "$PGBIN/psql" -h "$WORK" -p "$PORT" -U postgres -d postgres -qtAX "$@"; }

fails=0
for trial in 1 2 3; do
    tbl="t_$trial"
    # CREATE + INSERT + VACUUM, all in ONE session with NO delay in between,
    # so the inserting backend's pgstat delta is still pending at VACUUM time.
    PSQL -c "CREATE TABLE $tbl(i int);" \
         -c "INSERT INTO $tbl SELECT generate_series(1,10000);" \
         -c "VACUUM $tbl;" >/dev/null
    sleep 2   # let the pending delta flush (this is what clobbers the reset)
    ins=$(PSQL -c "SELECT n_ins_since_vacuum FROM pg_stat_user_tables WHERE relname='$tbl';")
    if [ "$ins" != "0" ]; then
        log "trial $trial: ANOMALY -- n_ins_since_vacuum=$ins after VACUUM (expected 0)"
        fails=$((fails+1))
    else
        log "trial $trial: ok -- n_ins_since_vacuum reset to 0"
    fi
done

log "reproduced in $fails/3 trials"
[ "$fails" -gt 0 ] && exit 1 || exit 0

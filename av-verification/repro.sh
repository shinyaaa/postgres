#!/bin/bash
# Minimal repro: on PostgreSQL master (20devel), autoanalyze is NOT logged even with
# log_autovacuum_min_duration=0, because master split the analyze logging threshold into a
# separate GUC `log_autoanalyze_min_duration` (default 600000ms = 10min).
#
# This is a behavior/observability change on master, NOT an autovacuum firing bug:
# the autoanalyze itself fires correctly (autoanalyze_count / last_autoanalyze update);
# only the server-log line is suppressed until the new GUC is lowered.
#
# Verified against HEAD 6d4ca6de97770cdaee18517dd2f8fe8f4ecee187.
# Run as an unprivileged user with the built binaries on PATH.
set -e
export PATH=$HOME/pgav/bin:$PATH
DATA=$HOME/repro-data

rm -rf "$DATA"
initdb -D "$DATA" --no-locale -E UTF8 >/dev/null
cat >> "$DATA/postgresql.conf" <<'EOF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
logging_collector = on
log_directory = 'log'
EOF
pg_ctl -D "$DATA" -l "$HOME/repro-start.log" start
sleep 3

psql -d postgres -c "SHOW log_autovacuum_min_duration;"   # 0
psql -d postgres -c "SHOW log_autoanalyze_min_duration;"  # 10min  <-- the culprit default

# Trigger a fast autoanalyze (100 inserts > analyze_threshold 50), suppress insert-vacuum.
psql -d postgres -c "CREATE TABLE r(a int) WITH (autovacuum_vacuum_insert_threshold=1000000000);
                     INSERT INTO r SELECT generate_series(1,100);"
sleep 6
echo "--- autoanalyze fired? (pgstat) ---"
psql -d postgres -c "SELECT relname, autoanalyze_count, last_autoanalyze IS NOT NULL AS aa_fired
                     FROM pg_stat_user_tables WHERE relname='r';"
echo "--- analyze log line with default (expect: NONE) ---"
grep -c "automatic analyze" "$DATA"/log/*.log || true

# Now lower the new GUC and repeat -> the log line appears.
psql -d postgres -c "ALTER SYSTEM SET log_autoanalyze_min_duration = 0;"
pg_ctl -D "$DATA" reload; sleep 1
psql -d postgres -c "CREATE TABLE r2(a int) WITH (autovacuum_vacuum_insert_threshold=1000000000);
                     INSERT INTO r2 SELECT generate_series(1,100);"
sleep 6
echo "--- analyze log line after log_autoanalyze_min_duration=0 (expect: present) ---"
grep "automatic analyze" "$DATA"/log/*.log || echo "NONE"

pg_ctl -D "$DATA" stop

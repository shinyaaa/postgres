-- breakdown_wal.sql
--
-- Diagnostic SQL to break down the WAL volume produced by a workload by
-- resource manager and record type, using pg_waldump.  Run after a controlled
-- COPY so the relevant range can be isolated.
--
-- Usage:
--   psql -d bench -v before='0/01000000' -v after='0/02000000' \
--        -f breakdown_wal.sql
--
-- It assumes pg_waldump is on PATH (or in the same bin/ as the running
-- server).  Also assumes the data directory is readable by the current user.

\set ON_ERROR_STOP on

-- 1) Run pg_waldump for the LSN range and capture per-record stats.
\set cmd '\\! pg_waldump --stats=record -s ' :before ' -e ' :after ' \
                       $(psql -tAc "SHOW data_directory")/pg_wal/* 2>/dev/null \
                       | tee /tmp/waldump_stats.txt'
:cmd

-- 2) Pull out just the heap2/multi_insert lines for quick comparison.
\! grep -E "MULTI_INSERT|heap_multi" /tmp/waldump_stats.txt || true

-- 3) Show overall WAL bytes
\! awk '/Total/{print}' /tmp/waldump_stats.txt

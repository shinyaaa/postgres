-- Premise verification for TOAST bloat visibility investigation
\set QUIET off
\timing off

-- Scenario: small parent table with a heavily-updated TOASTed column
CREATE TABLE t_wide (id int primary key, payload text);
ALTER TABLE t_wide ALTER COLUMN payload SET STORAGE EXTERNAL;
ALTER TABLE t_wide SET (autovacuum_enabled = off, toast.autovacuum_enabled = off);

-- 50 rows, each payload ~100kB -> ~50 toast chunks per row
INSERT INTO t_wide SELECT g, string_agg(md5(g::text || i::text), '')
  FROM generate_series(1, 50) g, generate_series(1, 3200) i GROUP BY g;

-- update the toasted column 20 times -> toast dead chunks pile up
DO $$
BEGIN
  FOR i IN 1..20 LOOP
    UPDATE t_wide SET payload = payload || i::text;
  END LOOP;
END $$;

SELECT pg_sleep(1);  -- let pgstat catch up

\echo === [A] toast rows ARE visible in pg_stat_all_tables ===
SELECT schemaname, relname, n_live_tup, n_dead_tup
  FROM pg_stat_all_tables WHERE schemaname = 'pg_toast'
   AND relid = (SELECT reltoastrelid FROM pg_class WHERE relname = 't_wide');

\echo === [B] ...but NOT in pg_stat_user_tables ===
SELECT count(*) AS toast_rows_in_user_tables
  FROM pg_stat_user_tables WHERE schemaname = 'pg_toast';

\echo === [C] parent vs toast dead tuples BEFORE vacuum ===
SELECT s.relname, s.n_live_tup, s.n_dead_tup
  FROM pg_stat_all_tables s
 WHERE s.relid IN ((SELECT oid FROM pg_class WHERE relname='t_wide'),
                   (SELECT reltoastrelid FROM pg_class WHERE relname='t_wide'));

-- vacuum ONLY the parent (simulates autovacuum choosing parent but not toast)
VACUUM (PROCESS_TOAST FALSE) t_wide;
SELECT pg_sleep(1);

\echo === [D] AFTER parent-only vacuum: parent looks healthy, toast still bloated ===
SELECT s.relname, s.n_live_tup, s.n_dead_tup, s.last_vacuum IS NOT NULL AS vacuumed
  FROM pg_stat_all_tables s
 WHERE s.relid IN ((SELECT oid FROM pg_class WHERE relname='t_wide'),
                   (SELECT reltoastrelid FROM pg_class WHERE relname='t_wide'));

\echo === [E] pg_table_size includes toast; heap alone is small ===
SELECT pg_size_pretty(pg_relation_size('t_wide')) AS heap_only,
       pg_size_pretty(pg_table_size('t_wide')) AS with_toast;

\echo === [F] the join users must write today to see toast from the parent ===
SELECT c.relname, ts.n_dead_tup AS toast_n_dead_tup,
       ts.last_autovacuum AS toast_last_autovacuum,
       ts.autovacuum_count AS toast_autovacuum_count
  FROM pg_class c
  JOIN pg_stat_all_tables ts ON ts.relid = c.reltoastrelid
 WHERE c.relname = 't_wide';

\echo === [G] pg_stat_autovacuum_scores includes the toast table (PG19 dev) ===
SELECT relname, schemaname, round(score::numeric, 3) AS score, do_vacuum
  FROM pg_stat_autovacuum_scores
 WHERE relid IN ((SELECT oid FROM pg_class WHERE relname='t_wide'),
                 (SELECT reltoastrelid FROM pg_class WHERE relname='t_wide'));

\echo === [H] toast.autovacuum_* reloptions land on the toast rel itself ===
SELECT c.relname, c.reloptions
  FROM pg_class c
 WHERE c.oid IN ((SELECT oid FROM pg_class WHERE relname='t_wide'),
                 (SELECT reltoastrelid FROM pg_class WHERE relname='t_wide'));

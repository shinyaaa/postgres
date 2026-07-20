-- 07_stats_leak.sql
-- Hypothesis (class 2): a user restricted by RLS can read MCV/histogram sample
-- values of rows they cannot SELECT, via pg_stats or the extended-stats views.
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS alice;
CREATE ROLE alice LOGIN;

CREATE TABLE t (id int, tenant text, secret text);
-- Load skewed data so MCV lists form; bob's secrets are the sensitive values.
INSERT INTO t SELECT g, 'bob', 'BOBSECRET-'||(g%3) FROM generate_series(1,2000) g;
INSERT INTO t SELECT g, 'alice', 'alicedata' FROM generate_series(1,50) g;
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
CREATE POLICY p ON t USING (tenant = current_user);
GRANT SELECT ON t TO alice;
-- extended stats over (tenant, secret)
CREATE STATISTICS s_ext (mcv) ON tenant, secret FROM t;
ANALYZE t;

\echo '=== alice cannot see bob rows via normal SELECT: ==='
SET ROLE alice;
SELECT count(*) AS visible_rows, count(DISTINCT secret) AS visible_secrets FROM t;
\echo '=== Can alice read bob secrets from pg_stats most_common_vals? ==='
SELECT attname, most_common_vals FROM pg_stats
  WHERE tablename='t' AND attname IN ('secret','tenant');
\echo '=== Can alice read bob secrets from extended-stats MCV (pg_statistic_ext_data / pg_stats_ext)? ==='
SELECT statistics_name, most_common_vals
  FROM pg_stats_ext WHERE tablename='t';
\echo '=== direct catalog access attempt ==='
SELECT stxdmcv IS NOT NULL AS has_mcv FROM pg_statistic_ext_data;
RESET ROLE;

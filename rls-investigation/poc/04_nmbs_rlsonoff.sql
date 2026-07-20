-- 04_nmbs_rlsonoff.sql : does NOT MATCHED BY SOURCE work at all, RLS off vs on?
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS alice;
CREATE ROLE alice LOGIN;

CREATE TABLE t (id int primary key, tenant text, secret text);
CREATE TABLE src (id int);
INSERT INTO src VALUES (99);  -- matches nothing in t
ALTER TABLE t OWNER TO alice;
ALTER TABLE src OWNER TO alice;

\echo '========== RLS OFF =========='
TRUNCATE t;
INSERT INTO t VALUES (1,'alice','A1'), (3,'alice','A3');
SET ROLE alice;
\echo 'NMBS DELETE, RLS OFF: expect delete id=1,3'
MERGE INTO t USING src ON t.id = src.id
  WHEN NOT MATCHED BY SOURCE THEN DELETE
  RETURNING merge_action(), t.*;
RESET ROLE;
SELECT count(*) AS remaining_rls_off FROM t;

\echo '========== RLS ON (ALL policy, alice owns all rows) =========='
TRUNCATE t;
INSERT INTO t VALUES (1,'alice','A1'), (3,'alice','A3');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
CREATE POLICY p ON t USING (tenant = current_user) WITH CHECK (tenant = current_user);
SET ROLE alice;
\echo 'alice sees her rows:'
SELECT * FROM t ORDER BY id;
\echo 'NMBS DELETE, RLS ON: expect delete id=1,3 (both hers)'
MERGE INTO t USING src ON t.id = src.id
  WHEN NOT MATCHED BY SOURCE THEN DELETE
  RETURNING merge_action(), t.*;
RESET ROLE;
SELECT count(*) AS remaining_rls_on FROM t;

\echo '========== Control: NOT MATCHED BY SOURCE UPDATE, RLS ON =========='
TRUNCATE t;
INSERT INTO t VALUES (1,'alice','A1'), (3,'alice','A3');
SET ROLE alice;
\echo 'NMBS UPDATE secret, RLS ON: expect update id=1,3'
MERGE INTO t USING src ON t.id = src.id
  WHEN NOT MATCHED BY SOURCE THEN UPDATE SET secret = 'upd'
  RETURNING merge_action(), t.*;
RESET ROLE;
SELECT * FROM t ORDER BY id;

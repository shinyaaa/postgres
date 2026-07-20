-- 06_nmbs_rls_clean.sql : clean NOT MATCHED BY SOURCE + RLS test
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t, src CASCADE;
DROP ROLE IF EXISTS alice, bob;
CREATE ROLE alice LOGIN;
CREATE ROLE bob LOGIN;

CREATE TABLE t (id int primary key, tenant text, secret text);
INSERT INTO t VALUES (1,'alice','A1'), (2,'bob','B2'), (3,'alice','A3'), (4,'bob','B4');
CREATE TABLE src (id int);
INSERT INTO src VALUES (99);   -- matches nothing -> every target row is NMBS
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
-- SELECT: see ALL.  UPDATE/DELETE: only own tenant.
CREATE POLICY psel ON t FOR SELECT USING (true);
CREATE POLICY pupd ON t FOR UPDATE USING (tenant = current_user) WITH CHECK (tenant = current_user);
CREATE POLICY pdel ON t FOR DELETE USING (tenant = current_user);
GRANT SELECT, INSERT, UPDATE, DELETE ON t TO alice, bob;
GRANT SELECT ON src TO alice, bob;

\echo '=== alice: NMBS DELETE. She sees all 4 (SELECT=true), may DELETE only alice rows (1,3).'
\echo '=== Correct RLS outcome: either delete only 1,3  OR  error on bob rows. NOT delete bob rows. ==='
SET ROLE alice;
MERGE INTO t USING src ON t.id = src.id
  WHEN NOT MATCHED BY SOURCE THEN DELETE
  RETURNING merge_action(), t.*;
RESET ROLE;
\echo '--- superuser view after: which rows survived? ---'
SELECT * FROM t ORDER BY id;

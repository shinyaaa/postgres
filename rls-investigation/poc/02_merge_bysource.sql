-- 02_merge_bysource.sql
-- Hypothesis: With a permissive SELECT policy (see all rows) but a restrictive
-- UPDATE/DELETE policy, MERGE ... WHEN NOT MATCHED BY SOURCE THEN UPDATE/DELETE
-- might act on rows the user is not allowed to UPDATE/DELETE.
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS rls_owner, alice, bob;
CREATE ROLE rls_owner LOGIN;
CREATE ROLE alice LOGIN;
CREATE ROLE bob   LOGIN;

SET ROLE rls_owner;
CREATE TABLE t (id int primary key, tenant text, secret text);
INSERT INTO t VALUES (1,'alice','A1'), (2,'bob','B2'), (3,'alice','A3'), (4,'bob','B4');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
-- SELECT: see ALL rows.  UPDATE/DELETE: only own tenant rows.
CREATE POLICY psel ON t FOR SELECT USING (true);
CREATE POLICY pupd ON t FOR UPDATE USING (tenant = current_user) WITH CHECK (tenant = current_user);
CREATE POLICY pdel ON t FOR DELETE USING (tenant = current_user);
GRANT SELECT, INSERT, UPDATE, DELETE ON t TO alice, bob;
CREATE TABLE src (id int, val text);
INSERT INTO src VALUES (1,'x');  -- only matches id=1 (alice's)
GRANT SELECT ON src TO alice, bob;
RESET ROLE;

-- alice runs MERGE that DELETEs every target row not present in src.
-- src only has id=1, so id=2,3,4 are "not matched by source".
-- id=2 and id=4 are bob's; alice must NOT be able to delete them.
SET ROLE alice;
\echo '--- alice: NOT MATCHED BY SOURCE DELETE (should error or skip bob rows) ---'
MERGE INTO t USING src ON t.id = src.id
  WHEN NOT MATCHED BY SOURCE THEN DELETE
  RETURNING merge_action(), t.*;
RESET ROLE;

\echo '--- Observer (superuser) after DELETE attempt: expect bob rows id=2,4 still present ---'
RESET ROLE;
SELECT * FROM t ORDER BY id;

\echo '--- alice: NOT MATCHED BY SOURCE UPDATE moving tenant (should error on bob rows) ---'
SET ROLE alice;
MERGE INTO t USING src ON t.id = src.id
  WHEN NOT MATCHED BY SOURCE THEN UPDATE SET secret = 'hacked'
  RETURNING merge_action(), t.*;
RESET ROLE;

\echo '--- Observer after UPDATE attempt: expect bob rows unchanged (B2,B4) ---'
SELECT * FROM t ORDER BY id;

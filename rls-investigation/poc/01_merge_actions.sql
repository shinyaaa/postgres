-- 01_merge_actions.sql
-- Hypothesis: MERGE may not enforce USING/WITH CHECK for every WHEN action
-- (UPDATE / DELETE / INSERT / DO NOTHING), letting a user touch or create rows
-- outside their policy.
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS rls_owner, alice, bob;
CREATE ROLE rls_owner LOGIN;
CREATE ROLE alice LOGIN;
CREATE ROLE bob   LOGIN;

SET ROLE rls_owner;
CREATE TABLE t (id int primary key, tenant text, secret text);
INSERT INTO t VALUES (1,'alice','A-secret'), (2,'bob','B-secret');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
-- USING and WITH CHECK both bound to tenant = current_user
CREATE POLICY p ON t USING (tenant = current_user) WITH CHECK (tenant = current_user);
GRANT SELECT, INSERT, UPDATE, DELETE ON t TO alice, bob;
RESET ROLE;

-- Source table (no RLS) holding candidate rows
SET ROLE rls_owner;
CREATE TABLE src (id int, tenant text, secret text);
INSERT INTO src VALUES (2,'bob','hijack'), (3,'alice','A-new'), (4,'bob','B-new');
GRANT SELECT ON src TO alice, bob;
RESET ROLE;

-- === alice tries to MERGE. She should only be able to see/modify id=3 (alice) ===
-- id=2 is bob's row (invisible to alice); id=4 is a new bob row (WITH CHECK should reject)
SET ROLE alice;
\echo '--- MERGE: matched update, not-matched insert ---'
MERGE INTO t USING src ON t.id = src.id
  WHEN MATCHED THEN UPDATE SET secret = src.secret
  WHEN NOT MATCHED THEN INSERT (id, tenant, secret) VALUES (src.id, src.tenant, src.secret)
  RETURNING merge_action(), t.*;
RESET ROLE;

\echo '--- Owner view after alice MERGE (expect: bob rows id=2 unchanged=B-secret; no id=4; id=3 alice inserted) ---'
SET ROLE rls_owner;
SELECT * FROM t ORDER BY id;
RESET ROLE;

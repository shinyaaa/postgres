-- 10_beginatomic_checkasuser.sql
-- (1) SQL-standard BEGIN ATOMIC function body referencing an RLS table:
--     does inlining + plan-cache role tracking still apply the executor's policy?
-- (2) checkAsUser: a NON-invoker view owned by a 3rd role should evaluate the
--     underlying RLS as the view owner regardless of who executes.
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS alice, bob, viewowner;
CREATE ROLE alice LOGIN;
CREATE ROLE bob LOGIN;
CREATE ROLE viewowner LOGIN;

CREATE TABLE t (id int, tenant text, secret text);
INSERT INTO t VALUES (1,'alice','A-secret'), (2,'bob','B-secret'), (3,'viewowner','V-secret');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
CREATE POLICY p ON t USING (tenant = current_user);
GRANT SELECT ON t TO alice, bob, viewowner;
SET plan_cache_mode = force_generic_plan;

\echo '########## (1) BEGIN ATOMIC set-returning function in FROM ##########'
CREATE FUNCTION getrows_atomic() RETURNS SETOF t
  LANGUAGE sql STABLE
  BEGIN ATOMIC
    SELECT * FROM t;
  END;
GRANT EXECUTE ON FUNCTION getrows_atomic() TO alice, bob;
SET ROLE alice;
PREPARE s1 AS SELECT tenant, secret FROM getrows_atomic() ORDER BY id;
\echo '-- alice (expect only alice):'
EXECUTE s1;
SET ROLE bob;
\echo '-- bob same prepared stmt (expect only bob, NOT alice):'
EXECUTE s1;
RESET ROLE;
DEALLOCATE s1;

\echo '########## (2) non-invoker view owned by viewowner; checkAsUser = viewowner ##########'
SET ROLE viewowner;
CREATE VIEW vo AS SELECT * FROM t;   -- security_invoker defaults to false
GRANT SELECT ON vo TO alice, bob;
RESET ROLE;
\echo '-- alice selects from vo: RLS of t evaluated as viewowner -> expect only V-secret row:'
SET ROLE alice;
SELECT tenant, secret FROM vo ORDER BY id;
SET ROLE bob;
\echo '-- bob selects from vo: also expect only V-secret (viewowner policy), not B-secret:'
SELECT tenant, secret FROM vo ORDER BY id;
RESET ROLE;

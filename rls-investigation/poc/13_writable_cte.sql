-- 13_writable_cte.sql : data-modifying WITH must enforce WITH CHECK and not
-- leak hidden rows through RETURNING inside the CTE.
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS alice;
CREATE ROLE alice LOGIN;
CREATE TABLE t (id int, tenant text, secret text);
INSERT INTO t VALUES (1,'alice','A1'), (2,'bob','B-HIDDEN');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
CREATE POLICY p ON t USING (tenant = current_user) WITH CHECK (tenant = current_user);
GRANT SELECT, INSERT, UPDATE, DELETE ON t TO alice;

\echo '=== (1) writable CTE INSERT violating WITH CHECK must error ==='
SET ROLE alice;
WITH ins AS (INSERT INTO t VALUES (3,'bob','evil') RETURNING *) SELECT * FROM ins;
\echo '=== (2) writable CTE UPDATE ... RETURNING cannot touch/read bob hidden row ==='
WITH upd AS (UPDATE t SET secret='x' WHERE id=2 RETURNING *) SELECT * FROM upd;
\echo '=== (3) writable CTE DELETE ... RETURNING cannot read bob hidden row ==='
WITH del AS (DELETE FROM t WHERE id=2 RETURNING *) SELECT * FROM del;
RESET ROLE;
\echo '=== observer: bob row intact, no id=3 ==='
SELECT * FROM t ORDER BY id;

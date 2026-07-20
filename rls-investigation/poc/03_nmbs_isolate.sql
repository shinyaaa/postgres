-- 03_nmbs_isolate.sql : isolate NOT MATCHED BY SOURCE + RLS behavior
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS alice;
CREATE ROLE alice LOGIN;

CREATE TABLE t (id int primary key, tenant text, secret text);
INSERT INTO t VALUES (1,'alice','A1'), (2,'bob','B2'), (3,'alice','A3');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
-- Single ALL policy: alice sees & modifies only her rows
CREATE POLICY p ON t USING (tenant = current_user) WITH CHECK (tenant = current_user);
GRANT SELECT, INSERT, UPDATE, DELETE ON t TO alice;
ALTER TABLE t OWNER TO alice;

CREATE TABLE src (id int);
INSERT INTO src VALUES (99);  -- matches nothing
GRANT SELECT ON src TO alice;

\echo '=== Case A: plain DELETE of own rows via NOT MATCHED BY SOURCE ==='
\echo 'alice sees id=1,3 (hers). src matches none -> both are NOT MATCHED BY SOURCE -> DELETE both.'
SET ROLE alice;
MERGE INTO t USING src ON t.id = src.id
  WHEN NOT MATCHED BY SOURCE THEN DELETE
  RETURNING merge_action(), t.*;
RESET ROLE;
\echo '--- superuser view: expect only id=2 (bob) remains ---'
SELECT * FROM t ORDER BY id;

\echo '=== Compare: equivalent plain DELETE ==='
DELETE FROM t;  -- reset via superuser? no, re-seed
TRUNCATE t;
INSERT INTO t VALUES (1,'alice','A1'), (2,'bob','B2'), (3,'alice','A3');
SET ROLE alice;
\echo 'Plain DELETE FROM t (alice) should delete her rows id=1,3'
DELETE FROM t RETURNING *;
RESET ROLE;
\echo '--- superuser view: expect only id=2 remains ---'
SELECT * FROM t ORDER BY id;

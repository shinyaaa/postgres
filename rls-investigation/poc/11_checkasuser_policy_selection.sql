-- 11_checkasuser_policy_selection.sql
-- Precisely test the checkAsUser path: a NON-invoker view should select the
-- VIEW OWNER's set of policies for the underlying RLS table, not the invoker's.
\set ON_ERROR_STOP 0
DROP VIEW IF EXISTS vo CASCADE;
DROP TABLE IF EXISTS t CASCADE;
DROP ROLE IF EXISTS alice, viewowner;
CREATE ROLE alice LOGIN;
CREATE ROLE viewowner LOGIN;

CREATE TABLE t (id int, label text);
INSERT INTO t VALUES (1,'row-for-alice'), (2,'row-for-viewowner'), (3,'row-for-nobody');
ALTER TABLE t ENABLE ROW LEVEL SECURITY;
ALTER TABLE t FORCE ROW LEVEL SECURITY;
-- Role-specific policies (fixed predicates, no current_user):
CREATE POLICY p_alice     ON t FOR SELECT TO alice     USING (id = 1);
CREATE POLICY p_viewowner ON t FOR SELECT TO viewowner USING (id = 2);
GRANT SELECT ON t TO alice, viewowner;

SET ROLE viewowner;
CREATE VIEW vo AS SELECT * FROM t;   -- non-invoker (definer-style)
GRANT SELECT ON vo TO alice;
RESET ROLE;

\echo '=== alice direct on t: expect only id=1 (p_alice) ==='
SET ROLE alice;
SELECT * FROM t ORDER BY id;
\echo '=== alice via non-invoker view vo: expect only id=2 (viewowner policy via checkAsUser) ==='
SELECT * FROM vo ORDER BY id;
RESET ROLE;

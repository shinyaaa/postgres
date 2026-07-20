-- 12_partition_returning_fk.sql
\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS p CASCADE;
DROP TABLE IF EXISTS ref CASCADE;
DROP ROLE IF EXISTS alice;
CREATE ROLE alice LOGIN;

\echo '############ (A) cross-partition UPDATE row movement: destination WITH CHECK ############'
CREATE TABLE p (id int, tenant text, secret text) PARTITION BY LIST (tenant);
CREATE TABLE p_alice PARTITION OF p FOR VALUES IN ('alice');
CREATE TABLE p_bob   PARTITION OF p FOR VALUES IN ('bob');
INSERT INTO p VALUES (1,'alice','A1');
ALTER TABLE p ENABLE ROW LEVEL SECURITY;
ALTER TABLE p FORCE ROW LEVEL SECURITY;
-- alice may see/modify only her rows, and WITH CHECK forbids creating non-alice rows
CREATE POLICY pp ON p USING (tenant = current_user) WITH CHECK (tenant = current_user);
GRANT SELECT, INSERT, UPDATE, DELETE ON p TO alice;
\echo '-- alice moves her row into bob partition (tenant alice->bob). WITH CHECK must reject. --'
SET ROLE alice;
UPDATE p SET tenant='bob' WHERE id=1 RETURNING *;
RESET ROLE;
\echo '-- observer: row must still be (1,alice,A1) --'
SELECT * FROM p ORDER BY id;

\echo '############ (B) RETURNING cannot read rows hidden by USING ############'
\echo '-- Give alice an UPDATE policy whose USING is TRUE but SELECT policy restricts. --'
DROP POLICY pp ON p;
CREATE POLICY p_sel ON p FOR SELECT USING (tenant = current_user);
CREATE POLICY p_upd ON p FOR UPDATE USING (true) WITH CHECK (true);
INSERT INTO p VALUES (2,'bob','B-HIDDEN');
SET ROLE alice;
\echo '-- alice UPDATE ... RETURNING on bob row: can she read B-HIDDEN via RETURNING? --'
UPDATE p SET secret = secret WHERE id = 2 RETURNING id, tenant, secret;
RESET ROLE;

\echo '############ (C) FK error message channel (RI runs as owner: known spec) ############'
CREATE TABLE ref (id int PRIMARY KEY, tenant text);
INSERT INTO ref VALUES (2,'bob');
ALTER TABLE ref ENABLE ROW LEVEL SECURITY;
ALTER TABLE ref FORCE ROW LEVEL SECURITY;
CREATE POLICY refp ON ref USING (tenant = current_user);
GRANT SELECT ON ref TO alice;
CREATE TABLE child (id int, ref_id int REFERENCES ref(id), tenant text);
ALTER TABLE child ENABLE ROW LEVEL SECURITY;
CREATE POLICY childp ON child USING (true) WITH CHECK (true);
GRANT INSERT, SELECT ON child TO alice;
SET ROLE alice;
\echo '-- alice cannot SELECT ref id=2 (bob), but can she confirm it exists via FK insert? --'
SELECT count(*) AS alice_sees_ref FROM ref;
INSERT INTO child VALUES (10, 2, 'alice');   -- FK to a row alice cannot see
\echo '-- and an FK to a nonexistent id for contrast --'
INSERT INTO child VALUES (11, 999, 'alice');
RESET ROLE;

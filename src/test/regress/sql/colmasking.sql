--
-- Test of column masking policies
--

-- Suppress NOTICE messages when users/groups don't exist
SET client_min_messages TO 'warning';

DROP ROLE IF EXISTS regress_cm_owner;
DROP ROLE IF EXISTS regress_cm_alice;
DROP ROLE IF EXISTS regress_cm_bob;
DROP ROLE IF EXISTS regress_cm_admin;

RESET client_min_messages;

CREATE ROLE regress_cm_owner;
CREATE ROLE regress_cm_alice;
CREATE ROLE regress_cm_bob;
CREATE ROLE regress_cm_admin BYPASSRLS;

SET SESSION AUTHORIZATION regress_cm_owner;

CREATE TABLE cm_employees (
    id      int PRIMARY KEY,
    name    text,
    ssn     text,
    salary  int,
    manager name
);

INSERT INTO cm_employees VALUES
    (1, 'anne',  '123-45-6789', 5000, 'regress_cm_alice'),
    (2, 'ben',   '987-65-4321', 6000, 'regress_cm_bob'),
    (3, 'carol', '555-11-2222', 7000, 'regress_cm_alice');

GRANT SELECT, INSERT, UPDATE, DELETE ON cm_employees
    TO regress_cm_alice, regress_cm_bob, regress_cm_admin;

-- conditional mask: rows satisfying USING show the real value
CREATE POLICY cm_mask_ssn ON cm_employees
    AS MASKING
    FOR SELECT
    TO PUBLIC
    USING (manager = current_user)
    MASK (ssn WITH '***-**-' || right(ssn, 4));

-- unconditional mask
CREATE POLICY cm_mask_salary ON cm_employees
    AS MASKING
    MASK (salary WITH NULL);

-- masking policies are not applied until COLUMN MASKING is enabled
SET SESSION AUTHORIZATION regress_cm_alice;
SELECT * FROM cm_employees ORDER BY id;
SET SESSION AUTHORIZATION regress_cm_owner;

ALTER TABLE cm_employees ENABLE COLUMN MASKING;

-- check the catalog representation
SELECT policyname, permissive, cmd, qual, masked_column, mask_expression
  FROM pg_policies WHERE tablename = 'cm_employees' ORDER BY policyname;

\d cm_employees

SELECT column_masking_active('cm_employees');
SELECT row_security_active('cm_employees');

-- invalid masking policy definitions
CREATE POLICY cm_err ON cm_employees AS MASKING MASK (ssn WITH 'x');  -- duplicate mask
CREATE POLICY cm_err ON cm_employees AS MASKING MASK (salary WITH 'not a number');  -- type mismatch
CREATE POLICY cm_err ON cm_employees AS MASKING FOR UPDATE MASK (name WITH 'x');  -- bad command
CREATE POLICY cm_err ON cm_employees AS MASKING WITH CHECK (true) MASK (name WITH 'x');  -- WITH CHECK
CREATE POLICY cm_err ON cm_employees FOR SELECT MASK (name WITH 'x');  -- MASK without MASKING
CREATE POLICY cm_err ON cm_employees AS MASKING;  -- MASKING without MASK
CREATE POLICY cm_err ON cm_employees AS MASKING MASK (nosuchcol WITH 'x');  -- bad column
CREATE POLICY cm_err ON cm_employees AS MASKING MASK (name WITH max(name));  -- no aggregates

-- sublinks are allowed in masking expressions
CREATE POLICY cm_sub ON cm_employees AS MASKING
    MASK (name WITH (SELECT 'x')::text);
DROP POLICY cm_sub ON cm_employees;

-- table owner is not masked
SELECT * FROM cm_employees ORDER BY id;

-- regress_cm_alice manages rows 1 and 3, so sees those SSNs unmasked
SET SESSION AUTHORIZATION regress_cm_alice;
SELECT * FROM cm_employees ORDER BY id;

-- predicates see masked values, so real values cannot be probed
SELECT count(*) FROM cm_employees WHERE ssn = '987-65-4321';
SELECT count(*) FROM cm_employees WHERE ssn = '***-**-4321';
SELECT count(*) FROM cm_employees WHERE ssn = '123-45-6789';

-- whole-row references see masked values too
SELECT row_to_json(e) FROM cm_employees e WHERE id = 2;

-- aggregates work over the masked values
SELECT count(DISTINCT salary) FROM cm_employees;

-- masked columns of a DML target relation cannot be referenced...
UPDATE cm_employees SET name = 'x' WHERE ssn = '987-65-4321';
UPDATE cm_employees SET name = ssn WHERE id = 2;
UPDATE cm_employees SET name = 'x' WHERE id = 2 RETURNING ssn;
UPDATE cm_employees SET name = 'x' WHERE id = 2 RETURNING cm_employees.*;
UPDATE cm_employees SET name = 'x' WHERE id = 2 RETURNING cm_employees;
DELETE FROM cm_employees WHERE ssn = '987-65-4321';
INSERT INTO cm_employees VALUES (4, 'dave', '111-22-3333', 100, NULL)
    ON CONFLICT (id) DO UPDATE SET name = excluded.name WHERE cm_employees.ssn <> '';

-- ...but writing them, or not referencing them, is fine
UPDATE cm_employees SET name = 'benny' WHERE id = 2;
UPDATE cm_employees SET ssn = '000-00-0000' WHERE id = 2;
INSERT INTO cm_employees VALUES (4, 'dave', '111-22-3333', 100, NULL);
DELETE FROM cm_employees WHERE id = 4;

-- row-level locking is not supported on masked relations
SELECT id FROM cm_employees WHERE id = 1 FOR UPDATE;

-- COPY TO applies masking
COPY cm_employees TO stdout;

-- masking applies within subqueries, CTEs and joins
WITH x AS (SELECT ssn FROM cm_employees WHERE id = 1) SELECT * FROM x;
SELECT e1.name, e2.ssn
  FROM cm_employees e1 JOIN cm_employees e2 ON e1.id = e2.id
 WHERE e1.id = 1;

-- INSERT ... SELECT from a masked table stores the masked values
SET SESSION AUTHORIZATION regress_cm_owner;
CREATE TABLE cm_snapshot AS SELECT * FROM cm_employees LIMIT 0;
GRANT SELECT, INSERT ON cm_snapshot TO regress_cm_bob;
SET SESSION AUTHORIZATION regress_cm_bob;
INSERT INTO cm_snapshot SELECT * FROM cm_employees WHERE id = 1;
SELECT * FROM cm_snapshot;

-- prepared statements are replanned when the role changes
PREPARE cm_p1 AS SELECT ssn FROM cm_employees WHERE id = 1;
EXECUTE cm_p1;
SET SESSION AUTHORIZATION regress_cm_alice;
EXECUTE cm_p1;
DEALLOCATE cm_p1;

-- BYPASSRLS roles bypass masking
SET SESSION AUTHORIZATION regress_cm_admin;
SELECT * FROM cm_employees ORDER BY id;

-- with row_security = off, masking is bypassed for those who may do so...
SET row_security = off;
SELECT * FROM cm_employees ORDER BY id;

-- ...but is an error for anybody else
SET SESSION AUTHORIZATION regress_cm_bob;
SELECT * FROM cm_employees ORDER BY id;
RESET row_security;

-- views: access through an owner's view is checked as the view owner
SET SESSION AUTHORIZATION regress_cm_owner;
CREATE VIEW cm_v_emp AS SELECT name, ssn FROM cm_employees;
CREATE VIEW cm_v_emp_inv WITH (security_invoker) AS
    SELECT name, ssn FROM cm_employees;
GRANT SELECT ON cm_v_emp, cm_v_emp_inv TO regress_cm_bob;
SET SESSION AUTHORIZATION regress_cm_bob;
SELECT * FROM cm_v_emp ORDER BY name;
SELECT * FROM cm_v_emp_inv ORDER BY name;

-- FORCE COLUMN MASKING applies masking to the table owner as well
SET SESSION AUTHORIZATION regress_cm_owner;
ALTER TABLE cm_employees FORCE COLUMN MASKING;
SELECT ssn, salary FROM cm_employees WHERE id = 2;
ALTER TABLE cm_employees NO FORCE COLUMN MASKING;
SELECT ssn, salary FROM cm_employees WHERE id = 2;

-- combination with row-level security
CREATE POLICY cm_rows ON cm_employees FOR SELECT USING (salary < 6500);
ALTER TABLE cm_employees ENABLE ROW LEVEL SECURITY;
SET SESSION AUTHORIZATION regress_cm_bob;
SELECT * FROM cm_employees ORDER BY id;
SET SESSION AUTHORIZATION regress_cm_owner;
ALTER TABLE cm_employees DISABLE ROW LEVEL SECURITY;
DROP POLICY cm_rows ON cm_employees;

-- DISABLE COLUMN MASKING stops applying the policies
ALTER TABLE cm_employees DISABLE COLUMN MASKING;
SET SESSION AUTHORIZATION regress_cm_bob;
SELECT * FROM cm_employees ORDER BY id;
SET SESSION AUTHORIZATION regress_cm_owner;
ALTER TABLE cm_employees ENABLE COLUMN MASKING;

-- masking policies on partitioned tables apply when accessed via the parent
CREATE TABLE cm_pt (id int, secret text, region text) PARTITION BY LIST (region);
CREATE TABLE cm_pt_a PARTITION OF cm_pt FOR VALUES IN ('a');
CREATE TABLE cm_pt_b PARTITION OF cm_pt FOR VALUES IN ('b');
INSERT INTO cm_pt VALUES (1, 's1', 'a'), (2, 's2', 'b');
GRANT SELECT ON cm_pt, cm_pt_a, cm_pt_b TO regress_cm_bob;
CREATE POLICY cm_mask_secret ON cm_pt AS MASKING MASK (secret WITH '<hidden>');
ALTER TABLE cm_pt ENABLE COLUMN MASKING;
SET SESSION AUTHORIZATION regress_cm_bob;
SELECT * FROM cm_pt ORDER BY id;
-- directly accessed partitions have no masking policies of their own
SELECT * FROM cm_pt_a ORDER BY id;
SET SESSION AUTHORIZATION regress_cm_owner;

-- a masked column cannot be dropped without CASCADE
ALTER TABLE cm_employees DROP COLUMN salary;
ALTER TABLE cm_employees DROP COLUMN salary CASCADE;
SET SESSION AUTHORIZATION regress_cm_bob;
SELECT * FROM cm_employees ORDER BY id;
SET SESSION AUTHORIZATION regress_cm_owner;

-- ALTER POLICY can change the roles and the USING expression
ALTER POLICY cm_mask_ssn ON cm_employees TO regress_cm_alice;
SET SESSION AUTHORIZATION regress_cm_bob;
SELECT ssn FROM cm_employees ORDER BY id;  -- policy no longer applies to bob
SET SESSION AUTHORIZATION regress_cm_alice;
SELECT ssn FROM cm_employees ORDER BY id;
SET SESSION AUTHORIZATION regress_cm_owner;
ALTER POLICY cm_mask_ssn ON cm_employees TO PUBLIC USING (false);
SET SESSION AUTHORIZATION regress_cm_alice;
SELECT ssn FROM cm_employees ORDER BY id;  -- now always masked
SET SESSION AUTHORIZATION regress_cm_owner;

-- masking expressions may not reference the table recursively
CREATE TABLE cm_rec (a int, b text);
GRANT SELECT ON cm_rec TO regress_cm_bob;
CREATE POLICY cm_rec_mask ON cm_rec AS MASKING
    MASK (b WITH (SELECT min(b) FROM cm_rec));
ALTER TABLE cm_rec ENABLE COLUMN MASKING;
SET SESSION AUTHORIZATION regress_cm_bob;
SELECT * FROM cm_rec;
SET SESSION AUTHORIZATION regress_cm_owner;

-- clean up
RESET SESSION AUTHORIZATION;
DROP VIEW cm_v_emp, cm_v_emp_inv;
DROP TABLE cm_employees, cm_snapshot, cm_pt, cm_rec;
DROP ROLE regress_cm_owner;
DROP ROLE regress_cm_alice;
DROP ROLE regress_cm_bob;
DROP ROLE regress_cm_admin;

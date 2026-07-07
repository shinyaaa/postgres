--
-- Tests for pg_rls_debugger
--
CREATE EXTENSION pg_rls_debugger;

CREATE ROLE regress_rlsdbg_alice;
CREATE ROLE regress_rlsdbg_bob;
CREATE ROLE regress_rlsdbg_admin BYPASSRLS;

CREATE SCHEMA rlsdbg;
GRANT USAGE ON SCHEMA rlsdbg
    TO regress_rlsdbg_alice, regress_rlsdbg_bob, regress_rlsdbg_admin;

CREATE TABLE rlsdbg.docs (
    id int PRIMARY KEY,
    owner name,
    tenant int,
    is_public bool,
    body text
);
INSERT INTO rlsdbg.docs VALUES
    (1, 'regress_rlsdbg_alice', 1, false, 'alice secret'),
    (2, 'regress_rlsdbg_bob',   1, false, 'bob secret'),
    (3, 'regress_rlsdbg_alice', 2, false, 'alice, wrong tenant'),
    (4, 'nobody',               1, true,  'public doc');
GRANT SELECT, INSERT, UPDATE, DELETE ON rlsdbg.docs
    TO regress_rlsdbg_alice, regress_rlsdbg_bob, regress_rlsdbg_admin;

-- Status before RLS is enabled
SELECT rls_enabled, rls_applied, policy_count, summary
  FROM pg_rls_status('rlsdbg.docs', 'regress_rlsdbg_alice');

ALTER TABLE rlsdbg.docs ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_owner ON rlsdbg.docs
    USING (owner = current_user);
CREATE POLICY p_public_read ON rlsdbg.docs FOR SELECT
    USING (is_public);
CREATE POLICY p_insert_self ON rlsdbg.docs FOR INSERT
    WITH CHECK (owner = current_user);
CREATE POLICY p_admin_all ON rlsdbg.docs TO regress_rlsdbg_admin
    USING (true);
CREATE POLICY r_tenant ON rlsdbg.docs AS RESTRICTIVE
    USING (tenant = 1);

-- Status: plain role, BYPASSRLS role, and superuser (never applied)
SELECT rls_enabled, rls_forced, rls_applied, policy_count, policies_for_role, summary
  FROM pg_rls_status('rlsdbg.docs', 'regress_rlsdbg_alice');
SELECT rls_applied, summary
  FROM pg_rls_status('rlsdbg.docs', 'regress_rlsdbg_admin');
SELECT rls_applied FROM pg_rls_status('rlsdbg.docs');

-- Policy listing
SELECT * FROM pg_rls_policies('rlsdbg.docs', 'regress_rlsdbg_bob');

-- Per-row, per-policy evaluation.
-- Row 1 (alice's, tenant 1) as alice: p_owner passes, r_tenant passes.
SELECT c.policy_name, c.policy_kind, c.applies_to_role, c.applies_to_cmd,
       c.using_result
  FROM rlsdbg.docs d,
       LATERAL pg_rls_check_row('rlsdbg.docs', d.ctid, 'regress_rlsdbg_alice') c
 WHERE d.id = 1;
-- Row 3 (alice's, tenant 2) as alice: restrictive r_tenant fails.
SELECT c.policy_name, c.policy_kind, c.using_result
  FROM rlsdbg.docs d,
       LATERAL pg_rls_check_row('rlsdbg.docs', d.ctid, 'regress_rlsdbg_alice') c
 WHERE d.id = 3;
-- UPDATE evaluates USING and WITH CHECK
SELECT c.policy_name, c.applies_to_cmd, c.using_result, c.check_result
  FROM rlsdbg.docs d,
       LATERAL pg_rls_check_row('rlsdbg.docs', d.ctid, 'regress_rlsdbg_bob', 'update') c
 WHERE d.id = 2;

-- Human-readable reports
SELECT pg_rls_why('rlsdbg.docs', d.ctid, 'regress_rlsdbg_alice', 'select')
  FROM rlsdbg.docs d WHERE d.id = 1;
SELECT pg_rls_why('rlsdbg.docs', d.ctid, 'regress_rlsdbg_alice', 'select')
  FROM rlsdbg.docs d WHERE d.id = 2;
SELECT pg_rls_why('rlsdbg.docs', d.ctid, 'regress_rlsdbg_alice', 'select')
  FROM rlsdbg.docs d WHERE d.id = 3;

-- Which rows can bob not see, and why?
SELECT row_data->>'id' AS id, reason
  FROM pg_rls_hidden_rows('rlsdbg.docs', 'regress_rlsdbg_bob')
 ORDER BY (row_data->>'id')::int;

-- Nothing is hidden from a role that bypasses RLS
SELECT count(*) FROM pg_rls_hidden_rows('rlsdbg.docs', 'regress_rlsdbg_admin');

-- UPDATE report warns when WITH CHECK does not pass for the current values
SELECT pg_rls_why('rlsdbg.docs', d.ctid, 'regress_rlsdbg_alice', 'update')
  FROM rlsdbg.docs d WHERE d.id = 3;

-- max_rows / scan_limit notices
SELECT count(*) FROM pg_rls_hidden_rows('rlsdbg.docs', 'regress_rlsdbg_bob', 'select', 1);
SELECT count(*) FROM pg_rls_hidden_rows('rlsdbg.docs', 'regress_rlsdbg_bob', 'select', 100, 2);

-- Test a hypothetical INSERT before running it
SELECT policy_name, check_expr, check_result
  FROM pg_rls_check_values('rlsdbg.docs',
                           '{"id": 99, "owner": "regress_rlsdbg_bob", "tenant": 1}',
                           'regress_rlsdbg_bob')
 WHERE applies_to_role AND applies_to_cmd;
SELECT policy_name, check_result
  FROM pg_rls_check_values('rlsdbg.docs',
                           '{"id": 99, "owner": "somebody_else", "tenant": 1}',
                           'regress_rlsdbg_bob')
 WHERE applies_to_role AND applies_to_cmd;

-- Owner and FORCE ROW LEVEL SECURITY
ALTER TABLE rlsdbg.docs OWNER TO regress_rlsdbg_alice;
SELECT rls_applied, summary
  FROM pg_rls_status('rlsdbg.docs', 'regress_rlsdbg_alice');
ALTER TABLE rlsdbg.docs FORCE ROW LEVEL SECURITY;
SELECT rls_applied, summary
  FROM pg_rls_status('rlsdbg.docs', 'regress_rlsdbg_alice');
ALTER TABLE rlsdbg.docs NO FORCE ROW LEVEL SECURITY;

-- Default deny: RLS enabled but no policies
CREATE TABLE rlsdbg.nopol (id int);
INSERT INTO rlsdbg.nopol VALUES (1);
GRANT SELECT ON rlsdbg.nopol TO regress_rlsdbg_bob;
ALTER TABLE rlsdbg.nopol ENABLE ROW LEVEL SECURITY;
SELECT rls_applied, summary
  FROM pg_rls_status('rlsdbg.nopol', 'regress_rlsdbg_bob');
SELECT row_data, reason
  FROM pg_rls_hidden_rows('rlsdbg.nopol', 'regress_rlsdbg_bob');
SELECT pg_rls_why('rlsdbg.nopol', n.ctid, 'regress_rlsdbg_bob')
  FROM rlsdbg.nopol n;

-- Unprivileged use: a role may debug itself (rows are fetched with its
-- own privileges, so it can only inspect rows it already sees)
SET SESSION AUTHORIZATION regress_rlsdbg_alice;
SELECT c.policy_name, c.using_result
  FROM rlsdbg.docs d,
       LATERAL pg_rls_check_row('rlsdbg.docs', d.ctid) c
 WHERE d.id = 1;
-- ... but may not debug as a role it is not a member of
SELECT * FROM pg_rls_check_row('rlsdbg.docs', '(0,1)', 'regress_rlsdbg_bob');
RESET SESSION AUTHORIZATION;

-- Error cases
SELECT * FROM pg_rls_check_row('rlsdbg.docs', '(0,999)');
SELECT * FROM pg_rls_status('rlsdbg.docs', 'regress_rlsdbg_nosuchrole');
SELECT * FROM pg_rls_check_row('rlsdbg.docs', '(0,1)', command := 'truncate');
SELECT * FROM pg_rls_check_values('rlsdbg.docs', '[1,2,3]');
CREATE VIEW rlsdbg.v AS SELECT 1 AS x;
SELECT * FROM pg_rls_status('rlsdbg.v');

-- A policy expression that errors at evaluation time is reported, not fatal
CREATE POLICY p_error ON rlsdbg.nopol
    USING (id = current_setting('rlsdbg.no_such_setting')::int);
SELECT c.policy_name, c.using_result
  FROM rlsdbg.nopol n,
       LATERAL pg_rls_check_row('rlsdbg.nopol', n.ctid, 'regress_rlsdbg_bob') c;

-- Clean up
DROP SCHEMA rlsdbg CASCADE;
DROP EXTENSION pg_rls_debugger;
DROP ROLE regress_rlsdbg_alice;
DROP ROLE regress_rlsdbg_bob;
DROP ROLE regress_rlsdbg_admin;

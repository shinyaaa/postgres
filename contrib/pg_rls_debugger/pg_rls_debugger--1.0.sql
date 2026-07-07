/* contrib/pg_rls_debugger/pg_rls_debugger--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_rls_debugger" to load this file. \quit

--
-- Internal helpers
--
-- All functions in this extension run with search_path pinned to
-- pg_catalog, so that policy expressions deparsed by pg_get_expr() come
-- out schema-qualified and can be re-executed safely, and so that no
-- user-created object can capture any reference made by our own SQL.
-- Because of that, internal cross-references must use @extschema@.
--

-- Verify that "rel" is something row-level security can apply to.
CREATE FUNCTION @extschema@._rls_debugger_check_rel(rel regclass)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    kind "char";
BEGIN
    SELECT c.relkind INTO kind FROM pg_class c WHERE c.oid = rel;
    IF kind IS NULL THEN
        RAISE EXCEPTION 'relation with OID % does not exist', rel::oid;
    END IF;
    IF kind NOT IN ('r', 'p') THEN
        RAISE EXCEPTION '"%" is not a table', rel
            USING DETAIL = 'Row-level security policies can only be defined on ordinary and partitioned tables.';
    END IF;
END;
$$;

-- Verify that "target_role" exists.
CREATE FUNCTION @extschema@._rls_debugger_check_role(target_role name)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF target_role IS NULL THEN
        RAISE EXCEPTION 'target role must not be null';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles r WHERE r.rolname = target_role) THEN
        RAISE EXCEPTION 'role "%" does not exist', target_role;
    END IF;
END;
$$;

-- Normalize a command word to the pg_policy.polcmd representation.
CREATE FUNCTION @extschema@._rls_debugger_cmd(command text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    CASE lower(command)
        WHEN 'select' THEN RETURN 'r';
        WHEN 'insert' THEN RETURN 'a';
        WHEN 'update' THEN RETURN 'w';
        WHEN 'delete' THEN RETURN 'd';
        ELSE
            RAISE EXCEPTION 'invalid command "%"', command
                USING HINT = 'Valid commands are SELECT, INSERT, UPDATE and DELETE.';
    END CASE;
END;
$$;

CREATE FUNCTION @extschema@._rls_debugger_cmdword(cmdc text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
RETURN CASE cmdc
    WHEN 'r' THEN 'SELECT'
    WHEN 'a' THEN 'INSERT'
    WHEN 'w' THEN 'UPDATE'
    WHEN 'd' THEN 'DELETE'
    ELSE 'ALL'
END;

-- Does a policy's role list cover "target_role"?  This mirrors the
-- backend's check_role_for_policy(): the policy applies if it is for
-- PUBLIC (polroles = {0}) or the role has the privileges of one of the
-- listed roles (has_privs_of_role, i.e. pg_has_role ... 'USAGE').
CREATE FUNCTION @extschema@._rls_debugger_role_matches(pol_roles oid[], target_role name)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
RETURN (pol_roles = '{0}'::oid[]
        OR EXISTS (SELECT 1 FROM unnest(pol_roles) AS r(roleid)
                   WHERE pg_has_role(target_role, r.roleid, 'USAGE')));

-- Fetch one row by ctid and return it as jsonb.  This runs with the
-- *caller's* privileges (and the caller's own RLS, if any), so it can
-- never show anybody a row they could not already see.
CREATE FUNCTION @extschema@._rls_debugger_fetch_row(rel regclass, row_ctid tid)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    row_json jsonb;
BEGIN
    PERFORM @extschema@._rls_debugger_check_rel(rel);
    EXECUTE format('SELECT to_jsonb(t) FROM ONLY %s t WHERE t.ctid = $1', rel)
        INTO row_json USING row_ctid;
    IF row_json IS NULL THEN
        RAISE EXCEPTION 'no row with ctid % in table %', row_ctid, rel
            USING HINT = 'The row does not exist, or it is hidden from you: rows are fetched with your own privileges and row-level security.';
    END IF;
    RETURN row_json;
END;
$$;

-- The core evaluator: run every policy of "rel" against one row (given
-- as jsonb), reporting the result of its USING and/or WITH CHECK
-- expression for the given command, as seen by "target_role".
--
-- The row is turned back into a composite of the table's row type, so
-- the policy expressions can be executed against it without touching
-- the table itself.  Each expression is executed under SET ROLE
-- target_role (which is why membership in that role is required), so
-- current_user, role-based functions and RLS of tables referenced in
-- sub-SELECTs behave exactly as they would for the target role.
CREATE FUNCTION @extschema@._rls_debugger_eval(
    rel regclass,
    row_data jsonb,
    target_role name,
    cmdc text)
RETURNS TABLE(
    policy_name name,
    policy_kind text,
    policy_cmd text,
    applies_to_role boolean,
    applies_to_cmd boolean,
    using_expr text,
    using_result text,
    check_expr text,
    check_result text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    saved_role text;
    rel_alias name;
    pol record;
    eval_sql text;
    passed boolean;
BEGIN
    PERFORM @extschema@._rls_debugger_check_rel(rel);
    PERFORM @extschema@._rls_debugger_check_role(target_role);

    SELECT c.relname INTO rel_alias FROM pg_class c WHERE c.oid = rel;

    saved_role := current_setting('role');

    -- Probe once whether we may become the target role at all, so the
    -- per-expression switches below cannot fail with a permission
    -- error halfway through.
    BEGIN
        PERFORM set_config('role', target_role::text, true);
        PERFORM set_config('role', saved_role, true);
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE EXCEPTION 'permission denied to debug as role "%"', target_role
            USING DETAIL = 'Policy expressions are evaluated with SET ROLE, which requires membership in the target role.',
                  HINT = 'Run this function as a member of the target role or as a superuser.';
    END;

    FOR pol IN
        SELECT p.polname AS p_name,
               p.polpermissive AS p_permissive,
               p.polcmd::text AS p_cmd,
               @extschema@._rls_debugger_role_matches(p.polroles, target_role) AS p_rolematch,
               pg_get_expr(p.polqual, p.polrelid) AS p_qual,
               pg_get_expr(p.polwithcheck, p.polrelid) AS p_check
        FROM pg_policy p
        WHERE p.polrelid = rel
        ORDER BY p.polname
    LOOP
        policy_name := pol.p_name;
        policy_kind := CASE WHEN pol.p_permissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END;
        policy_cmd := @extschema@._rls_debugger_cmdword(pol.p_cmd);
        applies_to_role := pol.p_rolematch;
        applies_to_cmd := pol.p_cmd IN ('*', cmdc);
        using_expr := pol.p_qual;
        -- Like the backend, an ALL/UPDATE policy without an explicit
        -- WITH CHECK falls back to its USING expression for checks.
        check_expr := COALESCE(pol.p_check, pol.p_qual);
        using_result := NULL;
        check_result := NULL;

        IF applies_to_role AND applies_to_cmd THEN
            IF cmdc IN ('r', 'w', 'd') AND using_expr IS NOT NULL THEN
                eval_sql := format(
                    'SELECT (%s) FROM (SELECT (jsonb_populate_record(NULL::%s, $1)).*) AS %I',
                    using_expr, rel, rel_alias);
                BEGIN
                    PERFORM set_config('role', target_role::text, true);
                    EXECUTE eval_sql INTO passed USING row_data;
                    PERFORM set_config('role', saved_role, true);
                    using_result := CASE WHEN passed IS NULL THEN 'null'
                                         WHEN passed THEN 'pass'
                                         ELSE 'fail' END;
                EXCEPTION WHEN OTHERS THEN
                    -- the aborted subtransaction has restored the role
                    using_result := 'error: ' || SQLERRM;
                END;
            END IF;
            IF cmdc IN ('a', 'w') AND check_expr IS NOT NULL THEN
                eval_sql := format(
                    'SELECT (%s) FROM (SELECT (jsonb_populate_record(NULL::%s, $1)).*) AS %I',
                    check_expr, rel, rel_alias);
                BEGIN
                    PERFORM set_config('role', target_role::text, true);
                    EXECUTE eval_sql INTO passed USING row_data;
                    PERFORM set_config('role', saved_role, true);
                    check_result := CASE WHEN passed IS NULL THEN 'null'
                                         WHEN passed THEN 'pass'
                                         ELSE 'fail' END;
                EXCEPTION WHEN OTHERS THEN
                    check_result := 'error: ' || SQLERRM;
                END;
            END IF;
        END IF;

        RETURN NEXT;
    END LOOP;
END;
$$;

-- Fold the per-policy results for one row into a single verdict, the
-- same way the executor combines policies: at least one PERMISSIVE
-- policy must pass, and every RESTRICTIVE policy must pass.  A NULL
-- result counts as failure, as it does for real RLS.
CREATE FUNCTION @extschema@._rls_debugger_verdict(
    rel regclass,
    row_data jsonb,
    target_role name,
    cmdc text)
RETURNS TABLE(visible boolean, reason text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    st record;
    n_perm bigint;
    n_perm_pass bigint;
    perm_detail text;
    perm_passed text[];
    restr_failed text[];
    parts text[] := '{}';
BEGIN
    SELECT * INTO st FROM @extschema@.pg_rls_status(rel, target_role);
    IF NOT st.rls_applied THEN
        visible := true;
        reason := st.summary;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT count(*) FILTER (WHERE e.policy_kind = 'PERMISSIVE'),
           count(*) FILTER (WHERE e.policy_kind = 'PERMISSIVE' AND e.relevant = 'pass'),
           string_agg(e.policy_name || ' => ' || COALESCE(e.relevant, '(no clause)'),
                      ', ' ORDER BY e.policy_name)
               FILTER (WHERE e.policy_kind = 'PERMISSIVE'),
           array_agg(e.policy_name::text ORDER BY e.policy_name)
               FILTER (WHERE e.policy_kind = 'PERMISSIVE' AND e.relevant = 'pass'),
           array_agg(e.policy_name::text ORDER BY e.policy_name)
               FILTER (WHERE e.policy_kind = 'RESTRICTIVE'
                       AND e.relevant IS NOT NULL AND e.relevant <> 'pass')
      INTO n_perm, n_perm_pass, perm_detail, perm_passed, restr_failed
      FROM (SELECT ev.policy_name, ev.policy_kind,
                   CASE WHEN cmdc = 'a' THEN ev.check_result
                        ELSE ev.using_result END AS relevant
            FROM @extschema@._rls_debugger_eval(rel, row_data, target_role, cmdc) ev
            WHERE ev.applies_to_role AND ev.applies_to_cmd) e;

    visible := n_perm_pass > 0 AND restr_failed IS NULL;

    IF visible THEN
        reason := 'allowed by permissive policy ' || array_to_string(perm_passed, ', ');
    ELSE
        IF n_perm = 0 THEN
            parts := parts || format('no permissive policy applies to role %s for %s (default deny)',
                                     target_role, @extschema@._rls_debugger_cmdword(cmdc));
        ELSIF n_perm_pass = 0 THEN
            parts := parts || ('no permissive policy passed: ' || perm_detail);
        END IF;
        IF restr_failed IS NOT NULL THEN
            parts := parts || ('restrictive policy failed: ' || array_to_string(restr_failed, ', '));
        END IF;
        reason := array_to_string(parts, '; ');
    END IF;
    RETURN NEXT;
END;
$$;

--
-- Public API
--

-- Is RLS applied to this role on this table at all, and why (not)?
-- The rls_applied logic mirrors the backend's check_enable_rls().
CREATE FUNCTION @extschema@.pg_rls_status(
    rel regclass,
    target_role name DEFAULT current_user)
RETURNS TABLE(
    rls_enabled boolean,
    rls_forced boolean,
    role_is_superuser boolean,
    role_has_bypassrls boolean,
    role_is_owner boolean,
    row_security_setting text,
    rls_applied boolean,
    policy_count integer,
    policies_for_role integer,
    summary text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rel_owner oid;
BEGIN
    PERFORM @extschema@._rls_debugger_check_rel(rel);
    PERFORM @extschema@._rls_debugger_check_role(target_role);

    SELECT c.relrowsecurity, c.relforcerowsecurity, c.relowner
      INTO rls_enabled, rls_forced, rel_owner
      FROM pg_class c WHERE c.oid = rel;

    SELECT r.rolsuper, r.rolbypassrls
      INTO role_is_superuser, role_has_bypassrls
      FROM pg_roles r WHERE r.rolname = target_role;

    role_is_owner := pg_has_role(target_role, rel_owner, 'USAGE');
    row_security_setting := current_setting('row_security');

    SELECT count(*)::integer,
           count(*) FILTER
               (WHERE @extschema@._rls_debugger_role_matches(p.polroles, target_role))::integer
      INTO policy_count, policies_for_role
      FROM pg_policy p WHERE p.polrelid = rel;

    -- Mirrors check_enable_rls(): superusers implicitly have BYPASSRLS;
    -- owners are exempt unless FORCE ROW LEVEL SECURITY is set.
    rls_applied := rls_enabled
                   AND NOT role_is_superuser
                   AND NOT role_has_bypassrls
                   AND (rls_forced OR NOT role_is_owner);

    IF NOT rls_enabled THEN
        summary := format('RLS is not enabled on %s; role %s is limited only by ordinary privileges', rel, target_role);
        IF policy_count > 0 THEN
            summary := summary || format(' (%s inactive policies exist - did you forget ALTER TABLE ... ENABLE ROW LEVEL SECURITY?)', policy_count);
        END IF;
    ELSIF role_is_superuser OR role_has_bypassrls THEN
        summary := format('RLS is enabled on %s but role %s bypasses it (%s)',
                          rel, target_role,
                          CASE WHEN role_is_superuser THEN 'superuser' ELSE 'BYPASSRLS' END);
    ELSIF role_is_owner AND NOT rls_forced THEN
        summary := format('RLS is enabled on %s but role %s owns the table and FORCE ROW LEVEL SECURITY is not set', rel, target_role);
    ELSE
        summary := format('RLS is applied to role %s on %s: %s of %s policies match the role',
                          target_role, rel, policies_for_role, policy_count);
        IF policies_for_role = 0 THEN
            summary := summary || ' - default deny, ALL rows are hidden';
        END IF;
        IF row_security_setting = 'off' THEN
            summary := summary || '; WARNING: row_security is off, queries by this role will fail with an error';
        END IF;
    END IF;

    RETURN NEXT;
END;
$$;

-- List all policies on a table and whether they cover a given role.
CREATE FUNCTION @extschema@.pg_rls_policies(
    rel regclass,
    target_role name DEFAULT current_user)
RETURNS TABLE(
    policy_name name,
    policy_kind text,
    policy_cmd text,
    policy_roles name[],
    applies_to_role boolean,
    using_expr text,
    check_expr text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM @extschema@._rls_debugger_check_rel(rel);
    PERFORM @extschema@._rls_debugger_check_role(target_role);

    RETURN QUERY
    SELECT p.polname,
           CASE WHEN p.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
           @extschema@._rls_debugger_cmdword(p.polcmd::text),
           CASE WHEN p.polroles = '{0}'::oid[] THEN ARRAY['public'::name]
                ELSE ARRAY(SELECT a.rolname FROM pg_roles a
                           WHERE a.oid = ANY (p.polroles) ORDER BY a.rolname)
           END,
           @extschema@._rls_debugger_role_matches(p.polroles, target_role),
           pg_get_expr(p.polqual, p.polrelid),
           pg_get_expr(p.polwithcheck, p.polrelid)
    FROM pg_policy p
    WHERE p.polrelid = rel
    ORDER BY p.polname;
END;
$$;

-- Evaluate every policy against one existing row, identified by ctid.
CREATE FUNCTION @extschema@.pg_rls_check_row(
    rel regclass,
    row_ctid tid,
    target_role name DEFAULT current_user,
    command text DEFAULT 'SELECT')
RETURNS TABLE(
    policy_name name,
    policy_kind text,
    policy_cmd text,
    applies_to_role boolean,
    applies_to_cmd boolean,
    using_expr text,
    using_result text,
    check_expr text,
    check_result text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM @extschema@._rls_debugger_eval(
        rel,
        @extschema@._rls_debugger_fetch_row(rel, row_ctid),
        target_role,
        @extschema@._rls_debugger_cmd(command));
END;
$$;

-- Evaluate every policy against a hypothetical row given as jsonb;
-- handy for testing WITH CHECK before an INSERT ever happens.
CREATE FUNCTION @extschema@.pg_rls_check_values(
    rel regclass,
    row_data jsonb,
    target_role name DEFAULT current_user,
    command text DEFAULT 'INSERT')
RETURNS TABLE(
    policy_name name,
    policy_kind text,
    policy_cmd text,
    applies_to_role boolean,
    applies_to_cmd boolean,
    using_expr text,
    using_result text,
    check_expr text,
    check_result text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF row_data IS NULL OR jsonb_typeof(row_data) <> 'object' THEN
        RAISE EXCEPTION 'row_data must be a jsonb object whose keys are column names';
    END IF;
    RETURN QUERY
    SELECT * FROM @extschema@._rls_debugger_eval(
        rel, row_data, target_role,
        @extschema@._rls_debugger_cmd(command));
END;
$$;

-- The one-stop answer to "why can't this role see this row?":
-- a human-readable report for a single row.
CREATE FUNCTION @extschema@.pg_rls_why(
    rel regclass,
    row_ctid tid,
    target_role name DEFAULT current_user,
    command text DEFAULT 'SELECT')
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    cmdc text;
    cmdword text;
    row_json jsonb;
    st record;
    e record;
    lines text[] := '{}';
    skip_why text;
    relevant text;
    n_match integer := 0;
    n_perm integer := 0;
    n_perm_pass integer := 0;
    perm_detail text[] := '{}';
    perm_passed text[] := '{}';
    restr_failed text[] := '{}';
    check_trouble text[] := '{}';
    parts text[] := '{}';
BEGIN
    cmdc := @extschema@._rls_debugger_cmd(command);
    cmdword := @extschema@._rls_debugger_cmdword(cmdc);
    row_json := @extschema@._rls_debugger_fetch_row(rel, row_ctid);
    SELECT * INTO st FROM @extschema@.pg_rls_status(rel, target_role);

    lines := lines || format('RLS debug report for table %s', rel);
    lines := lines || format('  row %s, role %s, command %s', row_ctid, target_role, cmdword);
    lines := lines || ('  status: ' || st.summary);
    lines := lines || ''::text;

    FOR e IN
        SELECT * FROM @extschema@._rls_debugger_eval(rel, row_json, target_role, cmdc)
    LOOP
        IF e.applies_to_role AND e.applies_to_cmd THEN
            n_match := n_match + 1;
            lines := lines || format('  %s policy %s (FOR %s):', e.policy_kind, e.policy_name, e.policy_cmd);
            IF cmdc IN ('r', 'w', 'd') THEN
                IF e.using_expr IS NULL THEN
                    lines := lines || '    (no USING clause)';
                ELSE
                    lines := lines || format('    USING (%s) => %s', e.using_expr, e.using_result);
                END IF;
            END IF;
            IF cmdc IN ('a', 'w') THEN
                IF e.check_expr IS NULL THEN
                    lines := lines || '    (no WITH CHECK clause)';
                ELSE
                    lines := lines || format('    WITH CHECK (%s) => %s', e.check_expr, e.check_result);
                END IF;
            END IF;

            relevant := CASE WHEN cmdc = 'a' THEN e.check_result ELSE e.using_result END;
            IF e.policy_kind = 'PERMISSIVE' THEN
                n_perm := n_perm + 1;
                perm_detail := perm_detail ||
                    (e.policy_name || ' => ' || COALESCE(relevant, '(no clause)'));
                IF relevant = 'pass' THEN
                    n_perm_pass := n_perm_pass + 1;
                    perm_passed := perm_passed || e.policy_name::text;
                END IF;
            ELSIF relevant IS NOT NULL AND relevant <> 'pass' THEN
                restr_failed := restr_failed || e.policy_name::text;
            END IF;
            IF cmdc = 'w' AND e.check_result IS NOT NULL AND e.check_result <> 'pass' THEN
                check_trouble := check_trouble || e.policy_name::text;
            END IF;
        ELSE
            skip_why := CASE
                WHEN NOT e.applies_to_role AND NOT e.applies_to_cmd THEN 'role and command do not match'
                WHEN NOT e.applies_to_role THEN 'role does not match'
                ELSE 'command does not match'
            END;
            lines := lines || format('  %s policy %s (FOR %s): skipped, %s',
                                     e.policy_kind, e.policy_name, e.policy_cmd, skip_why);
        END IF;
    END LOOP;

    lines := lines || ''::text;

    IF NOT st.rls_applied THEN
        lines := lines || format('VERDICT: RLS is NOT applied to role %s here; only ordinary privileges limit access.', target_role);
    ELSIF n_perm_pass > 0 AND cardinality(restr_failed) = 0 THEN
        lines := lines || format('VERDICT: role %s CAN %s this row (allowed by %s).',
                                 target_role, cmdword, array_to_string(perm_passed, ', '));
    ELSE
        IF n_perm = 0 THEN
            parts := parts || format('no permissive policy applies to role %s for %s (default deny)', target_role, cmdword);
        ELSIF n_perm_pass = 0 THEN
            parts := parts || ('no permissive policy passed: ' || array_to_string(perm_detail, ', '));
        END IF;
        IF cardinality(restr_failed) > 0 THEN
            parts := parts || ('restrictive policy failed: ' || array_to_string(restr_failed, ', '));
        END IF;
        lines := lines || format('VERDICT: role %s CANNOT %s this row.', target_role, cmdword);
        lines := lines || ('Reason: ' || array_to_string(parts, '; '));
    END IF;

    IF cmdc = 'w' AND st.rls_applied AND cardinality(check_trouble) > 0 THEN
        lines := lines || format('Note: WITH CHECK did not pass for %s when evaluated against the current row values; an UPDATE keeping these values would be rejected.',
                                 array_to_string(check_trouble, ', '));
    END IF;

    RETURN array_to_string(lines, E'\n');
END;
$$;

-- Scan a table (with the caller's privileges) and report which rows a
-- given role would NOT be able to see, and why.  Run this as the table
-- owner or a role with BYPASSRLS so the scan itself sees everything.
CREATE FUNCTION @extschema@.pg_rls_hidden_rows(
    rel regclass,
    target_role name DEFAULT current_user,
    command text DEFAULT 'SELECT',
    max_rows integer DEFAULT 100,
    scan_limit integer DEFAULT 10000)
RETURNS TABLE(
    row_ctid tid,
    row_data jsonb,
    reason text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    cmdc text;
    st record;
    r record;
    v record;
    scanned integer := 0;
    found integer := 0;
BEGIN
    cmdc := @extschema@._rls_debugger_cmd(command);
    SELECT * INTO st FROM @extschema@.pg_rls_status(rel, target_role);
    IF NOT st.rls_applied THEN
        RAISE NOTICE 'no rows are hidden: %', st.summary;
        RETURN;
    END IF;

    FOR r IN EXECUTE format('SELECT t.ctid AS row_ctid, to_jsonb(t) AS row_data FROM ONLY %s t LIMIT %s',
                            rel, scan_limit)
    LOOP
        scanned := scanned + 1;
        SELECT * INTO v
          FROM @extschema@._rls_debugger_verdict(rel, r.row_data, target_role, cmdc);
        IF NOT v.visible THEN
            row_ctid := r.row_ctid;
            row_data := r.row_data;
            reason := v.reason;
            RETURN NEXT;
            found := found + 1;
            IF found >= max_rows THEN
                RAISE NOTICE 'output limited to % hidden rows (max_rows); there may be more', max_rows;
                RETURN;
            END IF;
        END IF;
    END LOOP;

    IF scanned >= scan_limit THEN
        RAISE NOTICE 'only the first % rows were scanned (scan_limit); there may be more hidden rows', scan_limit;
    END IF;
END;
$$;

COMMENT ON FUNCTION @extschema@.pg_rls_status(regclass, name) IS
    'report whether row-level security is applied to a role on a table, and why (not)';
COMMENT ON FUNCTION @extschema@.pg_rls_policies(regclass, name) IS
    'list the RLS policies of a table and whether each one covers a role';
COMMENT ON FUNCTION @extschema@.pg_rls_check_row(regclass, tid, name, text) IS
    'evaluate every RLS policy of a table against one existing row, as a given role';
COMMENT ON FUNCTION @extschema@.pg_rls_check_values(regclass, jsonb, name, text) IS
    'evaluate every RLS policy of a table against a hypothetical row given as jsonb';
COMMENT ON FUNCTION @extschema@.pg_rls_why(regclass, tid, name, text) IS
    'human-readable report explaining why a role can or cannot access one row';
COMMENT ON FUNCTION @extschema@.pg_rls_hidden_rows(regclass, name, text, integer, integer) IS
    'scan a table and report the rows a role cannot see, with the reason';

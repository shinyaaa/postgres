--
-- Tests for pg_stat_role
--
-- Note on the expected statement counts: utility statements are charged
-- to the user that executes them, so a RESET ROLE issued while SET ROLE
-- is in effect is counted for the role being reset.
--

CREATE EXTENSION pg_stat_role;

SET pg_stat_role.track = on;

-- Roles and a table used throughout the test
CREATE ROLE pgsr_role1;
CREATE ROLE pgsr_role2;
CREATE ROLE pgsr_nopriv;

CREATE TABLE pgsr_tab AS SELECT g AS a FROM generate_series(1, 1000) g;
GRANT SELECT, INSERT ON pgsr_tab TO pgsr_role1, pgsr_role2;

--
-- Privileges: reading and resetting the statistics requires more than
-- an ordinary role.
--
SET ROLE pgsr_nopriv;
SELECT count(*) FROM pg_stat_role;			-- fail
SELECT count(*) FROM pg_stat_role_entries();	-- fail
SELECT pg_stat_role_reset();				-- fail
SELECT pg_stat_role_gc();					-- fail
RESET ROLE;

--
-- Basic attribution: statements and rows are charged to the role that
-- ran them.
--
SELECT pg_stat_role_reset();
SET ROLE pgsr_role1;
SELECT count(*) FROM pgsr_tab;
SELECT count(*) FROM pgsr_tab;
RESET ROLE;
SET ROLE pgsr_role2;
INSERT INTO pgsr_tab VALUES (0);
RESET ROLE;
SELECT pg_stat_force_next_flush();

-- pgsr_role1: 2 SELECTs + RESET ROLE; pgsr_role2: INSERT + RESET ROLE
SELECT rolname, statements, rows FROM pg_stat_role
  WHERE rolname IN ('pgsr_role1', 'pgsr_role2') ORDER BY rolname;

-- The reader touched blocks, the writer generated WAL
SELECT shared_blks_hit + shared_blks_read > 0 AS read_blocks,
       total_exec_time > 0 AS has_exec_time,
       cpu_user_time >= 0 AND cpu_system_time >= 0 AS cpu_sane
  FROM pg_stat_role WHERE rolname = 'pgsr_role1';
SELECT wal_records > 0 AS wrote_wal,
       wal_bytes > 0 AS wrote_wal_bytes
  FROM pg_stat_role WHERE rolname = 'pgsr_role2';

--
-- Nested statements: SQL run inside a function must not be counted
-- separately from the calling statement.
--
CREATE FUNCTION pgsr_nested() RETURNS bigint LANGUAGE plpgsql AS
$$
DECLARE r bigint;
BEGIN
  SELECT count(*) INTO r FROM pgsr_tab;
  SELECT count(*) INTO r FROM pgsr_tab;
  RETURN r;
END
$$;

SELECT pg_stat_role_reset();
SET ROLE pgsr_role1;
SELECT pgsr_nested() > 0 AS ok;
RESET ROLE;
SELECT pg_stat_force_next_flush();

-- 2 statements (the function call and RESET ROLE), not 4
SELECT statements, rows FROM pg_stat_role WHERE rolname = 'pgsr_role1';

--
-- SECURITY DEFINER: the whole statement is charged to the caller as of
-- statement start, not to the function owner.
--
CREATE FUNCTION pgsr_secdef() RETURNS bigint LANGUAGE sql SECURITY DEFINER
AS 'SELECT count(*) FROM pgsr_tab';
ALTER FUNCTION pgsr_secdef() OWNER TO pgsr_role2;

SELECT pg_stat_role_reset();
SET ROLE pgsr_role1;
SELECT pgsr_secdef() > 0 AS ok;
RESET ROLE;
SELECT pg_stat_force_next_flush();

SELECT rolname, statements, rows FROM pg_stat_role
  WHERE rolname IN ('pgsr_role1', 'pgsr_role2') ORDER BY rolname;

--
-- Parallel query: worker backends must not inflate the statement and
-- row counts.
--

-- encourage use of parallel plans
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;

EXPLAIN (COSTS OFF) SELECT count(*) FROM pgsr_tab;

SELECT pg_stat_role_reset();
SET ROLE pgsr_role1;
SELECT count(*) FROM pgsr_tab;
RESET ROLE;
SELECT pg_stat_force_next_flush();

-- 2 statements (SELECT and RESET ROLE), 1 row
SELECT statements, rows FROM pg_stat_role WHERE rolname = 'pgsr_role1';

RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_table_scan_size;
RESET max_parallel_workers_per_gather;

--
-- pg_stat_role.track = off disables collection
--
SELECT pg_stat_role_reset();
SET pg_stat_role.track = off;
SET ROLE pgsr_role1;
SELECT count(*) FROM pgsr_tab;
RESET ROLE;
SET pg_stat_role.track = on;
SELECT pg_stat_force_next_flush();

SELECT statements FROM pg_stat_role WHERE rolname = 'pgsr_role1';

--
-- Resetting a single role leaves the others alone
--
SELECT pg_stat_role_reset();
SET ROLE pgsr_role1;
SELECT count(*) FROM pgsr_tab;
RESET ROLE;
SET ROLE pgsr_role2;
SELECT count(*) FROM pgsr_tab;
RESET ROLE;
SELECT pg_stat_force_next_flush();
SELECT pg_stat_role_reset((SELECT oid FROM pg_roles WHERE rolname = 'pgsr_role1'));

SELECT rolname, statements, stats_reset IS NOT NULL AS has_reset
  FROM pg_stat_role
  WHERE rolname IN ('pgsr_role1', 'pgsr_role2') ORDER BY rolname;

--
-- DROP ROLE removes the role's entry; a rolled-back DROP ROLE does not.
--
CREATE ROLE pgsr_dropme;
GRANT SELECT ON pgsr_tab TO pgsr_dropme;
SET ROLE pgsr_dropme;
SELECT count(*) FROM pgsr_tab;
RESET ROLE;
SELECT pg_stat_force_next_flush();

SELECT count(*) FROM pg_stat_role WHERE rolname = 'pgsr_dropme';

BEGIN;
DROP OWNED BY pgsr_dropme;
DROP ROLE pgsr_dropme;
ROLLBACK;

SELECT count(*) FROM pg_stat_role WHERE rolname = 'pgsr_dropme';

DROP OWNED BY pgsr_dropme;
DROP ROLE pgsr_dropme;

-- no entry left behind for a role missing from pg_roles
SELECT count(*) FROM pg_stat_role_entries() e
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles r WHERE r.oid = e.roleid);

-- and consequently nothing for the garbage collector to do
SELECT pg_stat_role_gc();

-- Cleanup
DROP FUNCTION pgsr_nested();
DROP FUNCTION pgsr_secdef();
DROP TABLE pgsr_tab;
DROP ROLE pgsr_role1;
DROP ROLE pgsr_role2;
DROP ROLE pgsr_nopriv;
DROP EXTENSION pg_stat_role;

/* contrib/pg_stat_role/pg_stat_role--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_stat_role" to load this file. \quit

CREATE FUNCTION pg_stat_role_entries(
    OUT roleid oid,
    OUT statements bigint,
    OUT rows bigint,
    OUT total_exec_time double precision,
    OUT cpu_user_time double precision,
    OUT cpu_system_time double precision,
    OUT vol_context_switches bigint,
    OUT invol_context_switches bigint,
    OUT shared_blks_hit bigint,
    OUT shared_blks_read bigint,
    OUT shared_blks_dirtied bigint,
    OUT shared_blks_written bigint,
    OUT local_blks_hit bigint,
    OUT local_blks_read bigint,
    OUT local_blks_dirtied bigint,
    OUT local_blks_written bigint,
    OUT temp_blks_read bigint,
    OUT temp_blks_written bigint,
    OUT wal_records bigint,
    OUT wal_fpi bigint,
    OUT wal_bytes numeric,
    OUT stats_reset timestamp with time zone
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_role_entries'
LANGUAGE C VOLATILE PARALLEL RESTRICTED;

CREATE VIEW pg_stat_role AS
  SELECT
    s.roleid,
    r.rolname,
    s.statements,
    s.rows,
    s.total_exec_time,
    s.cpu_user_time,
    s.cpu_system_time,
    s.vol_context_switches,
    s.invol_context_switches,
    s.shared_blks_hit,
    s.shared_blks_read,
    s.shared_blks_dirtied,
    s.shared_blks_written,
    s.local_blks_hit,
    s.local_blks_read,
    s.local_blks_dirtied,
    s.local_blks_written,
    s.temp_blks_read,
    s.temp_blks_written,
    s.wal_records,
    s.wal_fpi,
    s.wal_bytes,
    s.stats_reset
  FROM pg_stat_role_entries() AS s
    LEFT JOIN pg_roles r ON r.oid = s.roleid;

CREATE FUNCTION pg_stat_role_reset(roleid oid DEFAULT NULL)
RETURNS void
AS 'MODULE_PATHNAME', 'pg_stat_role_reset'
LANGUAGE C VOLATILE CALLED ON NULL INPUT;

CREATE FUNCTION pg_stat_role_gc()
RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_stat_role_gc'
LANGUAGE C VOLATILE STRICT;

-- Per-role resource consumption can reveal information about other
-- tenants' activity, so restrict reading to pg_read_all_stats, like the
-- per-backend statistics views.  Reset and garbage collection stay
-- superuser-only unless explicitly granted.
REVOKE ALL ON pg_stat_role FROM PUBLIC;
GRANT SELECT ON pg_stat_role TO pg_read_all_stats;
REVOKE ALL ON FUNCTION pg_stat_role_entries() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_stat_role_entries() TO pg_read_all_stats;
REVOKE ALL ON FUNCTION pg_stat_role_reset(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION pg_stat_role_gc() FROM PUBLIC;

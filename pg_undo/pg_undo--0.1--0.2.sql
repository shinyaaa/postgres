/* pg_undo/pg_undo--0.1--0.2.sql */

\echo Use "ALTER EXTENSION pg_undo UPDATE TO '0.2'" to load this file. \quit

--
-- recycle bin for dropped tables
--
-- The ProcessUtility hook moves tables here instead of dropping them
-- (unless CASCADE is used or pg_undo.recycle_bin is off).  Trashed
-- tables keep their oid, owner, data, indexes and privileges.
--

CREATE SCHEMA undo_trash;

CREATE TABLE undo.trash_meta (
	trash_relid		regclass PRIMARY KEY,
	original_name	text NOT NULL,
	original_schema	text NOT NULL,
	dropped_at		timestamptz NOT NULL DEFAULT now(),
	dropped_by		name NOT NULL
);

CREATE VIEW undo.trash AS
SELECT m.original_schema,
	   m.original_name,
	   m.trash_relid AS trash_table,
	   m.dropped_at,
	   m.dropped_by,
	   pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(m.trash_relid)) AS size
  FROM undo.trash_meta m
 ORDER BY m.dropped_at DESC;

-- bring a dropped table back; picks the most recently dropped match
CREATE FUNCTION undo.restore_dropped(orig text, new_name text DEFAULT NULL)
RETURNS regclass
LANGUAGE plpgsql AS $fn$
DECLARE
	m undo.trash_meta;
	tgt text;
BEGIN
	SELECT * INTO m
	  FROM undo.trash_meta t
	 WHERE t.original_name = orig
		OR t.original_schema || '.' || t.original_name = orig
	 ORDER BY t.dropped_at DESC
	 LIMIT 1;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'pg_undo: no dropped table % in the recycle bin', orig;
	END IF;

	tgt := COALESCE(new_name, m.original_name);

	EXECUTE pg_catalog.format('ALTER TABLE %s SET SCHEMA %I',
							  m.trash_relid, m.original_schema);
	EXECUTE pg_catalog.format('ALTER TABLE %s RENAME TO %I',
							  m.trash_relid, tgt);
	DELETE FROM undo.trash_meta WHERE trash_relid = m.trash_relid;

	RAISE NOTICE 'pg_undo: restored %.%', m.original_schema, tgt;
	RETURN m.trash_relid;
END
$fn$;

-- permanently delete one table from the recycle bin
CREATE FUNCTION undo.purge(orig text) RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
	m undo.trash_meta;
BEGIN
	SELECT * INTO m
	  FROM undo.trash_meta t
	 WHERE t.original_name = orig
		OR t.original_schema || '.' || t.original_name = orig
	 ORDER BY t.dropped_at DESC
	 LIMIT 1;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'pg_undo: no dropped table % in the recycle bin', orig;
	END IF;

	EXECUTE pg_catalog.format('DROP TABLE %s CASCADE', m.trash_relid);
	DELETE FROM undo.trash_meta WHERE trash_relid = m.trash_relid;
END
$fn$;

-- empty the recycle bin
CREATE FUNCTION undo.purge_all() RETURNS bigint
LANGUAGE plpgsql AS $fn$
DECLARE
	m undo.trash_meta;
	n bigint := 0;
BEGIN
	FOR m IN SELECT * FROM undo.trash_meta LOOP
		EXECUTE pg_catalog.format('DROP TABLE IF EXISTS %s CASCADE', m.trash_relid);
		DELETE FROM undo.trash_meta WHERE trash_relid = m.trash_relid;
		n := n + 1;
	END LOOP;
	RETURN n;
END
$fn$;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA undo FROM PUBLIC;

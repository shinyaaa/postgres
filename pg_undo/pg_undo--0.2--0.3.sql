/* pg_undo/pg_undo--0.2--0.3.sql */

\echo Use "ALTER EXTENSION pg_undo UPDATE TO '0.3'" to load this file. \quit

--
-- time travel: reconstruct a tracked table's state at a past point in
-- time from undo.history
--
-- A row's state at time T is:
--   - its old image in the FIRST captured change touching it after T
--     (that change overwrote or deleted the state we want), or
--   - its current state, when nothing touched it after T, or
--   - absent, when its first post-T event is its own INSERT.
-- Primary-key updates are decomposed into a "gone" event for the old
-- identity and a "born" event for the new one.
--

-- raw (unquoted) primary key column names
CREATE FUNCTION undo._pk_cols_raw(rel regclass) RETURNS text[]
LANGUAGE sql STABLE AS $fn$
	SELECT array_agg(a.attname::text ORDER BY a.attnum)
	  FROM pg_catalog.pg_index i
	  JOIN pg_catalog.pg_attribute a
		ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
	 WHERE i.indrelid = rel AND i.indisprimary
$fn$;

-- guards shared by as_of and create_snapshot_view
CREATE FUNCTION undo._as_of_check(rel regclass, at timestamptz) RETURNS void
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
	v_tracked_at timestamptz;
BEGIN
	IF at IS NULL THEN
		RAISE EXCEPTION 'pg_undo: the point in time must not be NULL';
	END IF;
	SELECT t.tracked_at INTO v_tracked_at
	  FROM undo.tracked_tables t WHERE t.relid = rel;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'pg_undo: % is not tracked', rel;
	END IF;
	IF at < v_tracked_at THEN
		RAISE EXCEPTION 'pg_undo: history for % does not reach back to the requested time', rel;
	END IF;
	IF undo._pk_cols(rel) IS NULL THEN
		RAISE EXCEPTION 'pg_undo: as_of requires a primary key on %', rel;
	END IF;
	IF EXISTS (SELECT 1 FROM undo.history h
				WHERE h.relid = rel::oid AND h.op = 'T' AND h.changed_at > at) THEN
		RAISE EXCEPTION 'pg_undo: % was truncated after the requested time; its state cannot be reconstructed', rel;
	END IF;
END
$fn$;

-- SELECT * FROM undo.as_of(NULL::mytable, now() - interval '1 hour');
CREATE FUNCTION undo.as_of(rowtype anyelement, at timestamptz)
RETURNS SETOF anyelement
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
	v_rel regclass;
	rawpk text[];
	pk_old text;
	pk_new text;
	pk_live text;
	q text;
BEGIN
	SELECT t.typrelid INTO v_rel
	  FROM pg_catalog.pg_type t
	 WHERE t.oid = pg_catalog.pg_typeof(rowtype);
	IF v_rel IS NULL OR v_rel::oid = 0 THEN
		RAISE EXCEPTION 'pg_undo: pass a table row type, e.g. undo.as_of(NULL::mytable, ...)';
	END IF;

	PERFORM undo._as_of_check(v_rel, at);
	rawpk := undo._pk_cols_raw(v_rel);

	-- identity of a row image / live row as a text array of PK values;
	-- captured images store every value as its text representation, so
	-- live values are compared through ::text as well
	SELECT 'ARRAY[' || pg_catalog.string_agg(pg_catalog.format('h.old_row ->> %L', c), ', ') || ']'
	  INTO pk_old FROM pg_catalog.unnest(rawpk) c;
	SELECT 'ARRAY[' || pg_catalog.string_agg(pg_catalog.format('h.new_row ->> %L', c), ', ') || ']'
	  INTO pk_new FROM pg_catalog.unnest(rawpk) c;
	SELECT 'ARRAY[' || pg_catalog.string_agg(pg_catalog.format('t.%I::pg_catalog.text', c), ', ') || ']'
	  INTO pk_live FROM pg_catalog.unnest(rawpk) c;

	q := pg_catalog.format($q$
WITH ev AS (
	SELECT x.pk_key, x.kind, x.old_img, h.change_lsn
	  FROM undo.history h
	  CROSS JOIN LATERAL (VALUES
		(CASE WHEN h.op IN ('U', 'D') THEN %1$s END,
		 CASE WHEN h.op = 'D' THEN 'gone'
			  WHEN h.op = 'U' AND %1$s = %2$s THEN 'mod'
			  WHEN h.op = 'U' THEN 'gone' END,
		 h.old_row),
		(CASE WHEN h.op = 'I' THEN %2$s
			  WHEN h.op = 'U' AND %1$s <> %2$s THEN %2$s END,
		 'born',
		 NULL::pg_catalog.jsonb)
	  ) AS x(pk_key, kind, old_img)
	 WHERE h.relid = %3$s AND h.changed_at > %4$L AND h.op <> 'T'
	   AND x.pk_key IS NOT NULL AND x.kind IS NOT NULL
), first_ev AS (
	SELECT DISTINCT ON (pk_key) pk_key, kind, old_img
	  FROM ev
	 ORDER BY pk_key, change_lsn
)
SELECT t.* FROM %5$s t
 WHERE NOT EXISTS (SELECT 1 FROM first_ev f WHERE f.pk_key = %6$s)
UNION ALL
SELECT r.* FROM first_ev f
  CROSS JOIN LATERAL pg_catalog.jsonb_populate_record(NULL::%5$s, f.old_img) r
 WHERE f.kind IN ('mod', 'gone')
$q$,
						  pk_old, pk_new, v_rel::oid, at, v_rel, pk_live);

	RETURN QUERY EXECUTE q;
END
$fn$;

-- materialize the reconstruction as a temporary view for ad-hoc digging
CREATE FUNCTION undo.create_snapshot_view(rel regclass, at timestamptz,
										  view_name text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
	vname text;
BEGIN
	PERFORM undo._as_of_check(rel, at);
	vname := COALESCE(view_name,
					  (SELECT c.relname FROM pg_catalog.pg_class c
						WHERE c.oid = rel) || '_asof');
	EXECUTE pg_catalog.format(
		'CREATE TEMP VIEW %I AS SELECT * FROM undo.as_of(NULL::%s, %L::pg_catalog.timestamptz)',
		vname, rel, at);
	RAISE NOTICE 'pg_undo: created temporary view %', vname;
	RETURN vname;
END
$fn$;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA undo FROM PUBLIC;

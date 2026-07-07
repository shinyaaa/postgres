/* pg_undo/pg_undo--0.1.sql */

\echo Use "CREATE EXTENSION pg_undo" to load this file. \quit

CREATE SCHEMA undo;

--
-- configuration / state
--

CREATE TABLE undo.tracked_tables (
	relid			regclass PRIMARY KEY,
	tracked_at		timestamptz NOT NULL DEFAULT now(),
	prev_replident	"char" NOT NULL
);
SELECT pg_catalog.pg_extension_config_dump('undo.tracked_tables', '');

CREATE TABLE undo.progress (
	id					bool PRIMARY KEY DEFAULT true CHECK (id),
	last_commit_end_lsn	pg_lsn NOT NULL DEFAULT '0/0',
	capture_paused		bool NOT NULL DEFAULT false,
	paused_reason		text
);
INSERT INTO undo.progress DEFAULT VALUES;

--
-- captured history
--

CREATE TABLE undo.history (
	relid		oid			NOT NULL,
	change_lsn	pg_lsn		NOT NULL,
	commit_lsn	pg_lsn		NOT NULL,
	xid			bigint		NOT NULL,
	changed_at	timestamptz	NOT NULL,
	changed_by	name,		-- not available in 0.1 (WAL carries no role)
	op			"char"		NOT NULL,	-- 'I', 'U', 'D', 'T'
	old_row		jsonb,
	new_row		jsonb
);
CREATE INDEX history_rel_time_idx ON undo.history (relid, changed_at);
CREATE INDEX history_xid_idx ON undo.history (xid);
CREATE INDEX history_time_idx ON undo.history (changed_at);

--
-- track / untrack
--

CREATE FUNCTION undo.track(target regclass) RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
	v_kind "char";
	v_replident "char";
	v_nsp name;
	v_haspk boolean;
BEGIN
	SELECT c.relkind, c.relreplident, n.nspname
	  INTO v_kind, v_replident, v_nsp
	  FROM pg_catalog.pg_class c
	  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
	 WHERE c.oid = target;

	IF v_kind IS DISTINCT FROM 'r' THEN
		RAISE EXCEPTION 'pg_undo: % is not a regular table', target;
	END IF;
	IF v_nsp IN ('undo', 'pg_catalog', 'information_schema') THEN
		RAISE EXCEPTION 'pg_undo: cannot track %', target;
	END IF;

	SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_index i
					WHERE i.indrelid = target AND i.indisprimary)
	  INTO v_haspk;
	IF NOT v_haspk THEN
		RAISE WARNING 'pg_undo: % has no primary key; undo will match rows on the full row image',
			target;
	END IF;

	IF v_replident <> 'f' THEN
		EXECUTE pg_catalog.format('ALTER TABLE %s REPLICA IDENTITY FULL', target);
	END IF;

	INSERT INTO undo.tracked_tables (relid, prev_replident)
	VALUES (target, v_replident)
	ON CONFLICT (relid) DO NOTHING;

	RAISE NOTICE 'pg_undo: tracking %; history capture begins within pg_undo.naptime',
		target;
END
$fn$;

CREATE FUNCTION undo.untrack(target regclass) RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
	v_prev "char";
BEGIN
	DELETE FROM undo.tracked_tables WHERE relid = target
	RETURNING prev_replident INTO v_prev;

	IF NOT FOUND THEN
		RAISE NOTICE 'pg_undo: % was not tracked', target;
		RETURN;
	END IF;

	IF v_prev = 'd' THEN
		EXECUTE pg_catalog.format('ALTER TABLE %s REPLICA IDENTITY DEFAULT', target);
	ELSIF v_prev = 'n' THEN
		EXECUTE pg_catalog.format('ALTER TABLE %s REPLICA IDENTITY NOTHING', target);
	ELSIF v_prev = 'i' THEN
		RAISE WARNING 'pg_undo: % previously used REPLICA IDENTITY USING INDEX; leaving REPLICA IDENTITY FULL in place',
			target;
	END IF;
END
$fn$;

--
-- inspection
--

CREATE FUNCTION undo.recent_changes(target regclass, since interval DEFAULT '1 hour')
RETURNS TABLE (changed_at timestamptz, xid bigint, op "char", changed_by name,
			   old_row jsonb, new_row jsonb, change_lsn pg_lsn)
LANGUAGE sql STABLE AS $fn$
	SELECT h.changed_at, h.xid, h.op, h.changed_by, h.old_row, h.new_row, h.change_lsn
	  FROM undo.history h
	 WHERE h.relid = target::oid
	   AND h.changed_at >= pg_catalog.now() - since
	 ORDER BY h.change_lsn DESC
$fn$;

-- has the capture worker created its slot yet?  history capture only
-- covers changes made after this returns true
CREATE FUNCTION undo.ready() RETURNS boolean
LANGUAGE sql STABLE AS $fn$
	SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_replication_slots
					WHERE slot_name = 'pg_undo')
$fn$;

CREATE VIEW undo.status AS
SELECT (SELECT count(*) FROM undo.tracked_tables) AS tracked_tables,
	   (SELECT count(*) FROM undo.history) AS history_rows,
	   pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size('undo.history')) AS history_size,
	   p.last_commit_end_lsn,
	   p.capture_paused,
	   p.paused_reason,
	   s.confirmed_flush_lsn,
	   s.restart_lsn
  FROM undo.progress p
  LEFT JOIN pg_catalog.pg_replication_slots s ON s.slot_name = 'pg_undo';

--
-- internal helpers for inverse-DML generation
--

CREATE FUNCTION undo._pk_cols(rel regclass) RETURNS text[]
LANGUAGE sql STABLE AS $fn$
	SELECT array_agg(pg_catalog.quote_ident(a.attname) ORDER BY a.attnum)
	  FROM pg_catalog.pg_index i
	  JOIN pg_catalog.pg_attribute a
		ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
	 WHERE i.indrelid = rel AND i.indisprimary
$fn$;

CREATE FUNCTION undo._all_cols(rel regclass) RETURNS text[]
LANGUAGE sql STABLE AS $fn$
	SELECT array_agg(pg_catalog.quote_ident(attname) ORDER BY attnum)
	  FROM pg_catalog.pg_attribute
	 WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
$fn$;

-- columns that can appear in INSERT/UPDATE target lists
CREATE FUNCTION undo._writable_cols(rel regclass) RETURNS text[]
LANGUAGE sql STABLE AS $fn$
	SELECT array_agg(pg_catalog.quote_ident(attname) ORDER BY attnum)
	  FROM pg_catalog.pg_attribute
	 WHERE attrelid = rel AND attnum > 0 AND NOT attisdropped
	   AND attgenerated = ''
$fn$;

CREATE FUNCTION undo._row_expr(tab_alias text, cols text[]) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
	SELECT 'ROW(' || (SELECT pg_catalog.string_agg(tab_alias || '.' || c, ', ')
						FROM pg_catalog.unnest(cols) c) || ')'
$fn$;

-- EXISTS-style condition matching table alias "t" against a row image
CREATE FUNCTION undo._ident_cond(rel regclass, img jsonb) RETURNS text
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
	icols text[];
BEGIN
	icols := COALESCE(undo._pk_cols(rel), undo._all_cols(rel));
	RETURN pg_catalog.format(
		'EXISTS (SELECT 1 FROM pg_catalog.jsonb_populate_record(NULL::%s, %L::pg_catalog.jsonb) j WHERE %s IS NOT DISTINCT FROM %s)',
		rel, img::text,
		undo._row_expr('t', icols),
		undo._row_expr('j', icols));
END
$fn$;

-- inverse statement for one history row (NULL when not invertible)
CREATE FUNCTION undo._undo_sql(h undo.history) RETURNS text
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
	rel regclass := h.relid::regclass;
	wcols text[];
	collist text;
	overriding text := '';
BEGIN
	IF h.op = 'T' THEN
		RETURN NULL;			-- TRUNCATE is not invertible
	END IF;
	IF h.op IN ('U', 'D') AND h.old_row IS NULL THEN
		RETURN NULL;			-- no old image captured
	END IF;
	IF h.op IN ('U', 'I') AND h.new_row IS NULL THEN
		RETURN NULL;
	END IF;

	wcols := undo._writable_cols(rel);
	collist := pg_catalog.array_to_string(wcols, ', ');

	IF h.op = 'D' THEN
		IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
					WHERE attrelid = rel AND attnum > 0
					  AND NOT attisdropped AND attidentity = 'a') THEN
			overriding := 'OVERRIDING SYSTEM VALUE ';
		END IF;
		RETURN pg_catalog.format(
			'INSERT INTO %s (%s) %sSELECT %s FROM pg_catalog.jsonb_populate_record(NULL::%s, %L::pg_catalog.jsonb)',
			rel, collist, overriding, collist, rel, h.old_row::text);
	ELSIF h.op = 'U' THEN
		RETURN pg_catalog.format(
			'UPDATE %s t SET (%s) = (SELECT %s FROM pg_catalog.jsonb_populate_record(NULL::%s, %L::pg_catalog.jsonb)) WHERE %s',
			rel, collist, collist, rel, h.old_row::text,
			undo._ident_cond(rel, h.new_row));
	ELSIF h.op = 'I' THEN
		RETURN pg_catalog.format(
			'DELETE FROM %s t WHERE %s',
			rel, undo._ident_cond(rel, h.new_row));
	END IF;

	RETURN NULL;
END
$fn$;

-- has the state diverged from what undoing this change expects?
CREATE FUNCTION undo._has_conflict(h undo.history) RETURNS boolean
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
	rel regclass := h.relid::regclass;
	icols text[];
	acols text[];
	v boolean;
BEGIN
	IF h.op = 'T' THEN
		RETURN false;
	END IF;

	icols := COALESCE(undo._pk_cols(rel), undo._all_cols(rel));
	acols := undo._all_cols(rel);

	IF h.op = 'D' THEN
		IF h.old_row IS NULL THEN
			RETURN false;
		END IF;
		-- conflict if a row with the same identity already exists
		EXECUTE pg_catalog.format(
			'SELECT EXISTS (SELECT 1 FROM %s t, pg_catalog.jsonb_populate_record(NULL::%s, %L::pg_catalog.jsonb) j WHERE %s IS NOT DISTINCT FROM %s)',
			rel, rel, h.old_row::text,
			undo._row_expr('t', icols), undo._row_expr('j', icols))
		INTO v;
		RETURN v;
	ELSE
		IF h.new_row IS NULL THEN
			RETURN false;
		END IF;
		-- conflict unless a row identical to the post-change image remains
		EXECUTE pg_catalog.format(
			'SELECT NOT EXISTS (SELECT 1 FROM %s t, pg_catalog.jsonb_populate_record(NULL::%s, %L::pg_catalog.jsonb) j WHERE %s IS NOT DISTINCT FROM %s AND %s IS NOT DISTINCT FROM %s)',
			rel, rel, h.new_row::text,
			undo._row_expr('t', icols), undo._row_expr('j', icols),
			undo._row_expr('t', acols), undo._row_expr('j', acols))
		INTO v;
		RETURN v;
	END IF;
END
$fn$;

-- history rows matching a selector, newest change first
CREATE FUNCTION undo._changes(p_xid bigint, p_last interval,
							  p_since timestamptz, p_until timestamptz,
							  p_table regclass)
RETURNS SETOF undo.history
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
	v_since timestamptz;
	v_until timestamptz;
BEGIN
	IF p_xid IS NULL AND p_last IS NULL AND p_since IS NULL THEN
		RAISE EXCEPTION 'pg_undo: specify xid, last, or since/until';
	END IF;
	IF p_xid IS NOT NULL AND
	   (p_last IS NOT NULL OR p_since IS NOT NULL OR p_until IS NOT NULL) THEN
		RAISE EXCEPTION 'pg_undo: xid and a time range are mutually exclusive';
	END IF;

	IF p_xid IS NOT NULL THEN
		RETURN QUERY
			SELECT * FROM undo.history h
			 WHERE h.xid = p_xid
			   AND (p_table IS NULL OR h.relid = p_table::oid)
			 ORDER BY h.change_lsn DESC;
	ELSE
		v_since := COALESCE(p_since, pg_catalog.now() - p_last);
		v_until := COALESCE(p_until, 'infinity');
		RETURN QUERY
			SELECT * FROM undo.history h
			 WHERE h.changed_at >= v_since AND h.changed_at <= v_until
			   AND (p_table IS NULL OR h.relid = p_table::oid)
			 ORDER BY h.change_lsn DESC;
	END IF;
END
$fn$;

--
-- preview / apply
--

CREATE FUNCTION undo.preview(xid bigint DEFAULT NULL,
							 last interval DEFAULT NULL,
							 since timestamptz DEFAULT NULL,
							 until timestamptz DEFAULT NULL,
							 "table" regclass DEFAULT NULL)
RETURNS TABLE (seq bigint, target regclass, op "char", undo_sql text)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
	v_xid bigint := xid;
	v_last interval := last;
	v_since timestamptz := since;
	v_until timestamptz := until;
	v_table regclass := "table";
	h undo.history;
	v_seq bigint := 0;
BEGIN
	FOR h IN SELECT * FROM undo._changes(v_xid, v_last, v_since, v_until, v_table)
	LOOP
		v_seq := v_seq + 1;
		seq := v_seq;
		target := h.relid::regclass;
		op := h.op;
		undo_sql := undo._undo_sql(h);
		RETURN NEXT;
	END LOOP;
END
$fn$;

CREATE FUNCTION undo.apply(xid bigint DEFAULT NULL,
						   last interval DEFAULT NULL,
						   since timestamptz DEFAULT NULL,
						   until timestamptz DEFAULT NULL,
						   "table" regclass DEFAULT NULL,
						   on_conflict text DEFAULT 'abort')
RETURNS TABLE (applied bigint, skipped bigint, conflicts bigint)
LANGUAGE plpgsql AS $fn$
DECLARE
	v_xid bigint := xid;
	v_last interval := last;
	v_since timestamptz := since;
	v_until timestamptz := until;
	v_table regclass := "table";
	v_mode text := pg_catalog.lower(on_conflict);
	h undo.history;
	v_sql text;
	v_conflict boolean;
	v_applied bigint := 0;
	v_skipped bigint := 0;
	v_conflicts bigint := 0;
BEGIN
	IF v_mode NOT IN ('abort', 'skip', 'force') THEN
		RAISE EXCEPTION 'pg_undo: on_conflict must be ''abort'', ''skip'' or ''force''';
	END IF;

	FOR h IN SELECT * FROM undo._changes(v_xid, v_last, v_since, v_until, v_table)
	LOOP
		IF h.op = 'T' THEN
			IF v_mode = 'abort' THEN
				RAISE EXCEPTION 'pg_undo: a TRUNCATE of % cannot be undone',
					h.relid::regclass
					USING HINT = 'Re-run with on_conflict => ''skip'' to undo the remaining changes.';
			END IF;
			v_skipped := v_skipped + 1;
			CONTINUE;
		END IF;

		v_sql := undo._undo_sql(h);
		IF v_sql IS NULL THEN
			v_skipped := v_skipped + 1;
			CONTINUE;
		END IF;

		v_conflict := undo._has_conflict(h);
		IF v_conflict THEN
			v_conflicts := v_conflicts + 1;
			IF v_mode = 'abort' THEN
				RAISE EXCEPTION 'pg_undo: conflict while undoing % on %: the row was modified afterwards',
					h.op, h.relid::regclass
					USING HINT = 'Use on_conflict => ''skip'' or ''force''.';
			ELSIF v_mode = 'skip' THEN
				v_skipped := v_skipped + 1;
				CONTINUE;
			END IF;
		END IF;

		EXECUTE v_sql;
		v_applied := v_applied + 1;
	END LOOP;

	applied := v_applied;
	skipped := v_skipped;
	conflicts := v_conflicts;
	RETURN NEXT;
END
$fn$;

--
-- privileges: superuser-only by default; the schema grants nothing to
-- PUBLIC, and neither do the functions (history contains copies of all
-- tracked data).
--

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA undo FROM PUBLIC;

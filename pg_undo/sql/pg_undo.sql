CREATE EXTENSION pg_undo;

-- capture is asynchronous (bounded by pg_undo.naptime); poll instead of
-- asserting right after DML
CREATE FUNCTION wait_for_history(rel regclass, n bigint) RETURNS boolean AS $$
BEGIN
	FOR i IN 1..300 LOOP
		IF (SELECT count(*) FROM undo.history WHERE relid = rel::oid) >= n THEN
			RETURN true;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
	RETURN false;
END $$ LANGUAGE plpgsql;

-- capture only covers changes made after the worker created its slot
CREATE FUNCTION wait_ready() RETURNS boolean AS $$
BEGIN
	FOR i IN 1..300 LOOP
		IF undo.ready() THEN
			RETURN true;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
	RETURN false;
END $$ LANGUAGE plpgsql;
SELECT wait_ready();

--
-- track() validation
--
CREATE TABLE t1 (id int PRIMARY KEY, v text, big text);
SELECT undo.track('t1');
SELECT relreplident FROM pg_class WHERE oid = 't1'::regclass;
SELECT undo.track('t1');	-- idempotent

CREATE VIEW v1 AS SELECT 1 AS x;
SELECT undo.track('v1');	-- error: not a table

CREATE TABLE nopk (a int, b text);
SELECT undo.track('nopk');	-- warning: no primary key

--
-- DML capture, including TOAST handling
--
INSERT INTO t1 VALUES (1, 'one', repeat('x', 50000));
INSERT INTO t1 VALUES (2, 'two', 'small');
UPDATE t1 SET v = 'TWO' WHERE id = 2;
DELETE FROM t1 WHERE id = 1;
SELECT wait_for_history('t1', 4);

SELECT op, old_row ->> 'id' AS old_id, old_row ->> 'v' AS old_v,
	   new_row ->> 'id' AS new_id, new_row ->> 'v' AS new_v
  FROM undo.history
 WHERE relid = 't1'::regclass::oid
 ORDER BY change_lsn;

-- the unchanged 50kB TOAST value must be complete in both images
SELECT length(old_row ->> 'big') AS del_old_big
  FROM undo.history
 WHERE relid = 't1'::regclass::oid AND op = 'D';
SELECT length(new_row ->> 'big') AS ins_new_big
  FROM undo.history
 WHERE relid = 't1'::regclass::oid AND op = 'I' AND new_row ->> 'id' = '1';

--
-- recent_changes
--
SELECT op, old_row IS NOT NULL AS has_old, new_row IS NOT NULL AS has_new
  FROM undo.recent_changes('t1')
 ORDER BY change_lsn;

--
-- preview is non-mutating
--
SELECT count(*) FROM undo.preview(last => '10 minutes', "table" => 't1');
SELECT count(*) FROM t1;

--
-- apply, xid-scoped: bring back the deleted row
--
SELECT xid AS del_xid
  FROM undo.history
 WHERE relid = 't1'::regclass::oid AND op = 'D' \gset
SELECT * FROM undo.apply(xid => :del_xid);
SELECT id, v, length(big) FROM t1 ORDER BY id;

--
-- conflict handling: modify a row after the change being undone
--
SELECT xid AS upd_xid
  FROM undo.history
 WHERE relid = 't1'::regclass::oid AND op = 'U' \gset
UPDATE t1 SET v = 'TWO-again' WHERE id = 2;
SELECT wait_for_history('t1', 6);

SELECT * FROM undo.apply(xid => :upd_xid);						-- abort
SELECT * FROM undo.apply(xid => :upd_xid, on_conflict => 'skip');
SELECT v FROM t1 WHERE id = 2;
SELECT * FROM undo.apply(xid => :upd_xid, on_conflict => 'force');
SELECT v FROM t1 WHERE id = 2;
SELECT * FROM undo.apply(xid => :upd_xid, on_conflict => 'nonsense');	-- error

--
-- selector validation
--
SELECT * FROM undo.apply();										-- error
SELECT count(*) FROM undo.preview(xid => 1, last => '1 minute');	-- error

--
-- TRUNCATE is captured but not invertible
--
INSERT INTO nopk VALUES (1, 'x');
SELECT wait_for_history('nopk', 1);
TRUNCATE nopk;
SELECT wait_for_history('nopk', 2);
SELECT op FROM undo.history WHERE relid = 'nopk'::regclass::oid ORDER BY change_lsn;
SELECT * FROM undo.apply(last => '10 minutes', "table" => 'nopk');	-- abort on 'T'
SELECT applied, skipped >= 1 AS skipped_some, conflicts
  FROM undo.apply(last => '10 minutes', "table" => 'nopk', on_conflict => 'skip');

--
-- untrack restores the previous replica identity and stops capture
--
SELECT undo.untrack('t1');
SELECT relreplident FROM pg_class WHERE oid = 't1'::regclass;
SELECT undo.untrack('t1');	-- no longer tracked

SELECT pg_sleep(2);			-- let the worker drop t1 from its tracked set
INSERT INTO t1 VALUES (99, 'not captured', '');
SELECT pg_sleep(2);
SELECT count(*) FROM undo.history WHERE new_row ->> 'id' = '99';

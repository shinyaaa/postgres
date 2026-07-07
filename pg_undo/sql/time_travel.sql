--
-- time travel: undo.as_of reconstructs past table states
--
CREATE TABLE tt (id int PRIMARY KEY, v text);
SELECT undo.track('tt');
INSERT INTO tt VALUES (1, 'one'), (2, 'two'), (3, 'three');
SELECT wait_for_history('tt', 3);

SELECT now() AS t0 \gset

UPDATE tt SET v = 'TWO' WHERE id = 2;
DELETE FROM tt WHERE id = 3;
INSERT INTO tt VALUES (4, 'four');
SELECT wait_for_history('tt', 6);

-- current state
SELECT * FROM tt ORDER BY id;
-- state at t0: update reverted, deleted row visible, later insert absent
SELECT * FROM undo.as_of(NULL::tt, :'t0') ORDER BY id;

--
-- primary key updates decompose into gone + born
--
SELECT now() AS t1 \gset
UPDATE tt SET id = 40 WHERE id = 4;
SELECT wait_for_history('tt', 7);

SELECT * FROM undo.as_of(NULL::tt, :'t1') ORDER BY id;
SELECT * FROM undo.as_of(NULL::tt, now()) ORDER BY id;

--
-- snapshot view
--
SELECT undo.create_snapshot_view('tt', :'t0', 'tt_at_t0');
SELECT * FROM tt_at_t0 ORDER BY id;

--
-- guards
--
CREATE TABLE tt_untracked (id int PRIMARY KEY);
SELECT * FROM undo.as_of(NULL::tt_untracked, now());			-- not tracked
SELECT * FROM undo.as_of(NULL::tt, :'t0'::timestamptz - interval '1 day');	-- too early
SELECT * FROM undo.as_of(NULL::tt, NULL::timestamptz);			-- null time
CREATE TABLE nopk2 (a int);
SELECT undo.track('nopk2');
SELECT * FROM undo.as_of(NULL::nopk2, now());					-- needs a PK

-- a TRUNCATE after the requested time blocks reconstruction
TRUNCATE tt;
SELECT wait_for_history('tt', 8);
SELECT * FROM undo.as_of(NULL::tt, :'t0');						-- error

-- but times after the TRUNCATE work again
SELECT now() AS t2 \gset
INSERT INTO tt VALUES (100, 'after-truncate');
SELECT wait_for_history('tt', 9);
SELECT * FROM undo.as_of(NULL::tt, :'t2') ORDER BY id;
SELECT * FROM undo.as_of(NULL::tt, now()) ORDER BY id;

SELECT undo.untrack('tt');
SELECT undo.untrack('nopk2');

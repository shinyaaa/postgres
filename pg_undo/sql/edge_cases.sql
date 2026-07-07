--
-- edge cases: identifiers, data types, ordering, generated columns,
-- schemas, undo-of-undo, and recycle-bin corners
--

--
-- quoted identifiers and awkward column names round-trip
--
CREATE TABLE "Weird Table" (
	"Id" int PRIMARY KEY,
	"select" text,
	"col with space" text,
	"col""quote" text
);
SELECT undo.track('"Weird Table"');
INSERT INTO "Weird Table" VALUES (1, 'a', 'b', 'c');
UPDATE "Weird Table" SET "select" = 'x' WHERE "Id" = 1;
DELETE FROM "Weird Table";
SELECT wait_for_history('"Weird Table"', 3);
SELECT xid AS wt_del_xid FROM undo.history
 WHERE relid = '"Weird Table"'::regclass::oid AND op = 'D' \gset
SELECT * FROM undo.apply(xid => :wt_del_xid);
SELECT * FROM "Weird Table";

--
-- data types and NULL vs the string 'null'
--
CREATE TABLE typ (id int PRIMARY KEY, t text, b bytea, n numeric(10,4),
				  ts timestamptz, ia int[], j jsonb, f boolean);
SELECT undo.track('typ');
INSERT INTO typ VALUES
	(1, E'line1\nline2 ''q'' "dq" \\bs', '\xdeadbeef', 1234.5678,
	 '2026-01-02 03:04:05+00', '{1,2,3}', '{"k": [1, null, "v"]}', true);
INSERT INTO typ (id) VALUES (2);			-- all NULLs
INSERT INTO typ (id, t) VALUES (3, 'null');	-- the string, not NULL
DELETE FROM typ;
SELECT wait_for_history('typ', 6);
SELECT xid AS typ_del_xid FROM undo.history
 WHERE relid = 'typ'::regclass::oid AND op = 'D' LIMIT 1 \gset
SELECT * FROM undo.apply(xid => :typ_del_xid);
SELECT id, t, encode(b, 'hex') AS b, n, ts, ia, j, f FROM typ ORDER BY id;
SELECT id, t IS NULL AS t_is_null, t = 'null' AS t_is_the_string
  FROM typ ORDER BY id;

--
-- several changes to the same row unwind newest-first
--
CREATE TABLE mc (id int PRIMARY KEY, v int);
SELECT undo.track('mc');
INSERT INTO mc VALUES (1, 10);
SELECT wait_for_history('mc', 1);
SELECT now() AS mc_t0 \gset
UPDATE mc SET v = 20 WHERE id = 1;
UPDATE mc SET v = 30 WHERE id = 1;
DELETE FROM mc;
SELECT wait_for_history('mc', 4);
SELECT * FROM undo.apply(since => :'mc_t0', "table" => 'mc');
SELECT * FROM mc;

--
-- undo of the undo
--
SELECT wait_for_history('mc', 7);	-- the apply itself was captured
SELECT max(xid) AS mc_undo_xid FROM undo.history
 WHERE relid = 'mc'::regclass::oid \gset
SELECT * FROM undo.apply(xid => :mc_undo_xid);
SELECT count(*) AS back_to_deleted FROM mc;

--
-- INSERT + UPDATE + DELETE of one row in a single transaction nets to zero
--
CREATE TABLE onetxn (id int PRIMARY KEY, v text);
SELECT undo.track('onetxn');
BEGIN;
INSERT INTO onetxn VALUES (1, 'a');
UPDATE onetxn SET v = 'b' WHERE id = 1;
DELETE FROM onetxn;
COMMIT;
SELECT wait_for_history('onetxn', 3);
SELECT xid AS ot_xid FROM undo.history
 WHERE relid = 'onetxn'::regclass::oid LIMIT 1 \gset
SELECT * FROM undo.apply(xid => :ot_xid);
SELECT count(*) FROM onetxn;

--
-- undoing a primary-key UPDATE restores the old key
--
CREATE TABLE pkup (id int PRIMARY KEY, v text);
SELECT undo.track('pkup');
INSERT INTO pkup VALUES (1, 'x');
SELECT wait_for_history('pkup', 1);
SELECT now() AS pk_t0 \gset
UPDATE pkup SET id = 2 WHERE id = 1;
SELECT wait_for_history('pkup', 2);
SELECT * FROM undo.apply(since => :'pk_t0', "table" => 'pkup');
SELECT * FROM pkup;

--
-- generated columns are recomputed, identity columns restored verbatim
--
CREATE TABLE gen (id int PRIMARY KEY, a int,
				  dbl int GENERATED ALWAYS AS (a * 2) STORED);
SELECT undo.track('gen');
INSERT INTO gen VALUES (1, 21);
DELETE FROM gen;
SELECT wait_for_history('gen', 2);
SELECT xid AS gen_del_xid FROM undo.history
 WHERE relid = 'gen'::regclass::oid AND op = 'D' \gset
SELECT * FROM undo.apply(xid => :gen_del_xid);
SELECT * FROM gen;

CREATE TABLE idt (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v text);
SELECT undo.track('idt');
INSERT INTO idt (v) VALUES ('a'), ('b');
DELETE FROM idt;
SELECT wait_for_history('idt', 4);
SELECT xid AS idt_del_xid FROM undo.history
 WHERE relid = 'idt'::regclass::oid AND op = 'D' LIMIT 1 \gset
SELECT * FROM undo.apply(xid => :idt_del_xid);	-- OVERRIDING SYSTEM VALUE path
SELECT * FROM idt ORDER BY id;

--
-- tables without a primary key match on the full row image
--
CREATE TABLE norow (a int, v text);
SELECT undo.track('norow');
INSERT INTO norow VALUES (1, 'x'), (2, 'y');
SELECT wait_for_history('norow', 2);
SELECT now() AS nr_t0 \gset
UPDATE norow SET v = 'z' WHERE a = 1;
DELETE FROM norow WHERE a = 2;
SELECT wait_for_history('norow', 4);
SELECT * FROM undo.apply(since => :'nr_t0', "table" => 'norow');
SELECT * FROM norow ORDER BY a;

--
-- tables outside public
--
CREATE SCHEMA app;
CREATE TABLE app.orders (id int PRIMARY KEY, v text);
SELECT undo.track('app.orders');
INSERT INTO app.orders VALUES (1, 'o');
DELETE FROM app.orders;
SELECT wait_for_history('app.orders', 2);
SELECT xid AS ord_del_xid FROM undo.history
 WHERE relid = 'app.orders'::regclass::oid AND op = 'D' \gset
SELECT * FROM undo.apply(xid => :ord_del_xid);
SELECT * FROM app.orders;

--
-- one apply can span several tables; an empty window applies nothing
--
CREATE TABLE w1 (id int PRIMARY KEY);
CREATE TABLE w2 (id int PRIMARY KEY);
SELECT undo.track('w1');
SELECT undo.track('w2');
INSERT INTO w1 VALUES (1);
INSERT INTO w2 VALUES (1);
SELECT wait_for_history('w1', 1);
SELECT wait_for_history('w2', 1);
SELECT now() AS w_t0 \gset
DELETE FROM w1;
DELETE FROM w2;
SELECT wait_for_history('w1', 2);
SELECT wait_for_history('w2', 2);
SELECT * FROM undo.apply(since => :'w_t0');
SELECT (SELECT count(*) FROM w1) AS w1_rows, (SELECT count(*) FROM w2) AS w2_rows;
SELECT * FROM undo.apply(since => now() + interval '1 hour');

--
-- privileges: ordinary users cannot see history
--
CREATE ROLE regress_pg_undo_nosuper;
SET SESSION AUTHORIZATION regress_pg_undo_nosuper;
SELECT count(*) FROM undo.history;					-- denied
SELECT * FROM undo.preview(last => '1 minute');		-- denied
RESET SESSION AUTHORIZATION;
DROP ROLE regress_pg_undo_nosuper;

--
-- recycle bin corners: quoted names, non-public schemas, FK-referenced
-- tables (which the bin diverts even though plain DROP RESTRICT would
-- refuse: nothing is lost, the dependency follows the table)
--
CREATE TABLE "Drop Me" (id int PRIMARY KEY);
DROP TABLE "Drop Me";
SELECT undo.restore_dropped('Drop Me');
SELECT count(*) FROM "Drop Me";

CREATE TABLE app.victim (id int PRIMARY KEY);
DROP TABLE app.victim;
SELECT original_schema, original_name FROM undo.trash;
SELECT undo.restore_dropped('app.victim');
SELECT 'app.victim'::regclass;

CREATE TABLE fk_parent (id int PRIMARY KEY);
CREATE TABLE fk_child (pid int REFERENCES fk_parent);
DROP TABLE fk_parent;			-- binned; plain DROP would raise RESTRICT
SELECT conname FROM pg_constraint WHERE conrelid = 'fk_child'::regclass;
SELECT undo.restore_dropped('fk_parent');
INSERT INTO fk_parent VALUES (1);
INSERT INTO fk_child VALUES (1);	-- FK still enforced after the round trip
INSERT INTO fk_child VALUES (99);	-- error

--
-- cleanup
--
SELECT undo.untrack('"Weird Table"');
SELECT undo.untrack('typ');
SELECT undo.untrack('mc');
SELECT undo.untrack('onetxn');
SELECT undo.untrack('pkup');
SELECT undo.untrack('gen');
SELECT undo.untrack('idt');
SELECT undo.untrack('norow');
SELECT undo.untrack('app.orders');
SELECT undo.untrack('w1');
SELECT undo.untrack('w2');
SELECT undo.purge_all();

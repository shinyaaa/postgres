--
-- recycle bin: DROP TABLE is diverted to undo_trash
--
CREATE TABLE dt (id serial PRIMARY KEY, v text);
INSERT INTO dt (v) VALUES ('a'), ('b');
DROP TABLE dt;
SELECT count(*) AS in_public FROM pg_class
 WHERE relname = 'dt' AND relnamespace = 'public'::regnamespace;
SELECT original_schema, original_name FROM undo.trash;

-- restore brings back data, indexes and the owned sequence
SELECT undo.restore_dropped('dt');
SELECT * FROM dt ORDER BY id;
INSERT INTO dt (v) VALUES ('c') RETURNING id;

--
-- same-named tables can coexist in the bin (oid-suffixed names)
--
DROP TABLE dt;
CREATE TABLE dt (id serial PRIMARY KEY, v text);
INSERT INTO dt (v) VALUES ('second');
DROP TABLE dt;
SELECT count(*) AS dt_in_trash FROM undo.trash_meta WHERE original_name = 'dt';

-- newest first; the older one can be restored under a new name
SELECT undo.restore_dropped('dt');
SELECT v FROM dt;
SELECT undo.restore_dropped('dt', 'dt_old');
SELECT v FROM dt_old ORDER BY v;
SELECT undo.restore_dropped('dt');	-- error: bin is empty for dt

-- IF EXISTS keeps its usual behavior
DROP TABLE IF EXISTS no_such_table;

--
-- bypasses
--
CREATE TABLE gone (id int);
DROP TABLE gone CASCADE;			-- CASCADE destroys for real
SELECT count(*) AS gone_in_trash FROM undo.trash_meta WHERE original_name = 'gone';

CREATE TEMP TABLE tt (id int);
DROP TABLE tt;						-- temp tables are never binned
SELECT count(*) AS tt_in_trash FROM undo.trash_meta WHERE original_name = 'tt';

-- a multi-object DROP with any non-binnable target bypasses entirely
CREATE TABLE m1 (id int);
CREATE TEMP TABLE m2 (id int);
DROP TABLE m1, m2;
SELECT count(*) AS m_in_trash FROM undo.trash_meta
 WHERE original_name IN ('m1', 'm2');

-- superusers can opt out per session
CREATE TABLE really_gone (id int);
SET pg_undo.recycle_bin = off;
DROP TABLE really_gone;
RESET pg_undo.recycle_bin;
SELECT count(*) AS really_gone_in_trash FROM undo.trash_meta
 WHERE original_name = 'really_gone';

--
-- dependent objects follow the table into the bin instead of raising
-- the usual RESTRICT error
--
CREATE TABLE base_t (id int PRIMARY KEY);
INSERT INTO base_t VALUES (42);
CREATE VIEW base_v AS SELECT * FROM base_t;
DROP TABLE base_t;
SELECT * FROM base_v;				-- still works, reading from the bin
SELECT undo.restore_dropped('base_t');
DROP VIEW base_v;

--
-- non-superusers: drops are escalated into the bin, but bin management
-- and the bypass GUC stay privileged
--
CREATE ROLE regress_pg_undo_user;
CREATE TABLE user_t (id int PRIMARY KEY);
ALTER TABLE user_t OWNER TO regress_pg_undo_user;
SET SESSION AUTHORIZATION regress_pg_undo_user;
SET pg_undo.recycle_bin = off;		-- error: superuser-only
DROP TABLE user_t;
SELECT undo.restore_dropped('user_t');	-- error: no execute privilege
RESET SESSION AUTHORIZATION;
SELECT original_name, dropped_by FROM undo.trash
 WHERE original_name = 'user_t';

--
-- purge
--
SELECT undo.purge('user_t');
SELECT undo.purge_all() AS purged;
SELECT count(*) AS bin_size FROM undo.trash_meta;
DROP ROLE regress_pg_undo_user;

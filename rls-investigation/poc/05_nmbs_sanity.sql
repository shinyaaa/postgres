\set ON_ERROR_STOP 0
DROP TABLE IF EXISTS t2, src2 CASCADE;
CREATE TABLE t2 (id int primary key, v text);
INSERT INTO t2 VALUES (1,'a'),(2,'b'),(3,'c');
CREATE TABLE src2 (id int);
INSERT INTO src2 VALUES (1);   -- matches id=1 only
\echo '-- NMBS DELETE with src matching id=1: expect delete id=2,3 --'
MERGE INTO t2 USING src2 ON t2.id = src2.id
  WHEN NOT MATCHED BY SOURCE THEN DELETE
  RETURNING merge_action(), t2.*;
SELECT * FROM t2 ORDER BY id;
\echo '-- Now empty-match: src only id=99 --'
TRUNCATE t2; INSERT INTO t2 VALUES (1,'a'),(2,'b'),(3,'c');
DELETE FROM src2; INSERT INTO src2 VALUES (99);
MERGE INTO t2 USING src2 ON t2.id = src2.id
  WHEN NOT MATCHED BY SOURCE THEN DELETE
  RETURNING merge_action(), t2.*;
SELECT * FROM t2 ORDER BY id;
\echo '-- Now empty source table entirely --'
TRUNCATE t2; INSERT INTO t2 VALUES (1,'a'),(2,'b'),(3,'c');
TRUNCATE src2;
MERGE INTO t2 USING src2 ON t2.id = src2.id
  WHEN NOT MATCHED BY SOURCE THEN DELETE
  RETURNING merge_action(), t2.*;
SELECT * FROM t2 ORDER BY id;

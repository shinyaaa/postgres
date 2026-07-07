\timing on
DROP TABLE IF EXISTS cx;
CREATE TABLE cx(a int, b text);
INSERT INTO cx SELECT g, md5(g::text) FROM generate_series(1,3000000) g;
DELETE FROM cx WHERE a % 2 = 0;

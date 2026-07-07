\timing on
DROP TABLE IF EXISTS mp;
CREATE TABLE mp(a int, b text);
INSERT INTO mp SELECT g, md5(g::text) FROM generate_series(1,5000000) g;
CREATE INDEX mp_a ON mp(a);
CREATE INDEX mp_b ON mp(b);
DELETE FROM mp WHERE a % 2 = 0;
SELECT count(*) AS live_after_delete FROM mp;

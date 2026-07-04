-- Generate activity across shared stat kinds (except lock, done separately).
SET client_min_messages = warning;
DROP TABLE IF EXISTS fill_t;
CREATE TABLE fill_t (id int primary key, v text);
INSERT INTO fill_t SELECT g, repeat('x', 100) FROM generate_series(1, 5000) g;
CREATE INDEX fill_idx ON fill_t (v);
UPDATE fill_t SET v = v || 'y' WHERE id % 3 = 0;
DELETE FROM fill_t WHERE id % 7 = 0;
VACUUM fill_t;
SELECT count(*) FROM fill_t;                 -- reads/hits (io)
CHECKPOINT;                                   -- checkpointer + wal
SELECT txid_current();                        -- slru (subtrans/xact), wal
SELECT pg_stat_force_next_flush();

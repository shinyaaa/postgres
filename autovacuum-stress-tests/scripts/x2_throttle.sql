ALTER TABLE cx SET (autovacuum_vacuum_cost_delay = 20, autovacuum_vacuum_cost_limit = 100,
                    autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 1000);
-- create fresh dead tuples to trigger a new (throttled => slow) autovacuum
DELETE FROM cx WHERE a % 4 = 1;
SELECT count(*) FILTER (WHERE true) AS live FROM cx;

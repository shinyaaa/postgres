DO $$ BEGIN FOR i IN 1..120 LOOP EXECUTE format('create table if not exists fp_%s(x int)', i); END LOOP; END $$;
SELECT pg_stat_reset_shared('lock');
BEGIN;
DO $$ BEGIN FOR i IN 1..120 LOOP EXECUTE format('select * from fp_%s', i); END LOOP; END $$;
SELECT 1;
COMMIT;

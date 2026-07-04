BEGIN;
DO $$ BEGIN FOR i IN 1..40 LOOP EXECUTE format('select * from fpx_%s', i); END LOOP; END $$;
COMMIT;

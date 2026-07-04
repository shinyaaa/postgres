DO $$ BEGIN FOR i IN 1..40 LOOP EXECUTE format('create table if not exists fpx_%s(x int)', i); END LOOP; END $$;

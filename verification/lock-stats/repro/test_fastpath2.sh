#!/bin/bash
export PGI=/root/pgi
P="$PGI/bin/psql -X -d postgres"
ML=$($P -A -t -c "SHOW max_locks_per_transaction")
echo "max_locks_per_transaction=$ML"
cat > /home/pgtest/fp2.sql <<SQL
DROP TABLE IF EXISTS part_test;
CREATE TABLE part_test(id int) PARTITION BY RANGE (id);
DO \$\$
DECLARE max_locks int := current_setting('max_locks_per_transaction')::int;
BEGIN
  FOR i IN 1..(max_locks + 10) LOOP
    EXECUTE format('CREATE TABLE part_test_%s PARTITION OF part_test FOR VALUES FROM (%s) TO (%s)', i, (i-1)*1000, i*1000);
  END LOOP;
END;
\$\$;
SQL
$P -f /home/pgtest/fp2.sql >/dev/null 2>&1
$P -c "SELECT pg_stat_reset_shared('lock');" >/dev/null
echo "-- before: global & backend fastpath_exceeded"
$P -A -t -c "SELECT 'global='||fastpath_exceeded FROM pg_stat_lock WHERE locktype='relation';"
# Take AccessShareLock on all partitions in one query, then flush in SAME session (backend stats need same live backend)
cat > /home/pgtest/fp2run.sql <<SQL
SELECT fastpath_exceeded AS b_before FROM pg_stat_get_backend_lock(pg_backend_pid()) WHERE locktype='relation' \\gset
SELECT count(*) FROM part_test;
SELECT pg_stat_force_next_flush();
SELECT 'backend_before='|| :b_before ;
SELECT 'backend_after='||fastpath_exceeded FROM pg_stat_get_backend_lock(pg_backend_pid()) WHERE locktype='relation';
SQL
$P -f /home/pgtest/fp2run.sql
sleep 1
echo "-- after: global"
$P -c "SELECT locktype,waits,wait_time,fastpath_exceeded FROM pg_stat_lock WHERE locktype='relation';"

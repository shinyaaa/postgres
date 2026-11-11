# Tests for the locks taken by ALTER TABLE ... SET (storage_parameter).
#
# The autovacuum cost delay parameters take a lock that does not conflict
# with VACUUM.  Concurrent changes of storage parameters are still
# serialized.

setup
{
	CREATE TABLE reloptions_tab (a int, b text);
}

teardown
{
	DROP TABLE reloptions_tab;
}

session s1
step s1_begin		{ BEGIN; }
# The same lock as VACUUM takes
step s1_lock		{ LOCK TABLE reloptions_tab IN SHARE UPDATE EXCLUSIVE MODE; }
step s1_delay		{ ALTER TABLE reloptions_tab SET (autovacuum_vacuum_cost_delay = 1); }
step s1_commit		{ COMMIT; }

session s2
step s2_limit		{ ALTER TABLE reloptions_tab SET (autovacuum_vacuum_cost_limit = 100, toast.autovacuum_vacuum_cost_limit = 200); }
step s2_reset		{ ALTER TABLE reloptions_tab RESET (autovacuum_vacuum_cost_limit); }
step s2_fillfactor	{ ALTER TABLE reloptions_tab SET (fillfactor = 90); }
step s2_mixed		{ ALTER TABLE reloptions_tab SET (autovacuum_vacuum_cost_delay = 2, fillfactor = 90); }
step s2_show
{
	SELECT c.reloptions, t.reloptions AS toast_reloptions
	  FROM pg_class c JOIN pg_class t ON t.oid = c.reltoastrelid
	  WHERE c.relname = 'reloptions_tab';
}

# The cost delay parameters can be changed while the table is locked as for
# VACUUM.
permutation s1_begin s1_lock s2_limit s2_show s2_reset s2_show s1_commit

# Other parameters wait, also when combined with a cost delay parameter.
permutation s1_begin s1_lock s2_fillfactor s1_commit s2_show
permutation s1_begin s1_lock s2_mixed s1_commit s2_show

# Concurrent changes wait for each other, and none is lost.
permutation s1_begin s1_delay s2_limit s1_commit s2_show
permutation s1_begin s1_delay s2_fillfactor s1_commit s2_show

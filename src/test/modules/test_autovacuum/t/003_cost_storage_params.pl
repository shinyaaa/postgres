# Copyright (c) 2026, PostgreSQL Global Development Group

# Test that changing the cost-related storage parameters of a table takes
# effect in the autovacuum worker that is processing it.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Create a test node with autovacuum disabled.  The cost delay settings make
# autovacuum so slow that it cannot finish the tables below within the test's
# timeout.
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf(
	'postgresql.conf', qq{
autovacuum = off
autovacuum_naptime = '1s'
autovacuum_vacuum_cost_delay = '100ms'
autovacuum_vacuum_cost_limit = 1
log_min_messages = 'warning, autovacuum:debug2'
});
$node->start;

# The TOAST table is left alone until the second test.
$node->safe_psql(
	'postgres', qq{
  CREATE TABLE cost_heap (i int);
  INSERT INTO cost_heap SELECT generate_series(1, 200000);
  DELETE FROM cost_heap;

  CREATE TABLE cost_toast (i int, j text STORAGE EXTERNAL)
    WITH (autovacuum_enabled = false, toast.autovacuum_enabled = false);
  INSERT INTO cost_toast SELECT g, repeat('a', 10000) FROM generate_series(1, 600) g;
  DELETE FROM cost_toast;
});

my $heap = $node->safe_psql('postgres', "SELECT 'cost_heap'::regclass::oid");
my $toast = $node->safe_psql('postgres',
	"SELECT reltoastrelid FROM pg_class WHERE oid = 'cost_toast'::regclass");

# Wait for an autovacuum worker to start vacuuming the given table, change a
# storage parameter of "table" and verify that the worker picks it up and
# finishes.
sub test_cost_change
{
	my ($relid, $table, $testname) = @_;

	ok( $node->poll_query_until(
			'postgres',
			"SELECT count(*) = 1 FROM pg_stat_progress_vacuum WHERE relid = $relid"
		),
		"$testname: autovacuum started");

	my $offset = -s $node->logfile;
	$node->safe_psql('postgres',
		"ALTER TABLE $table SET (autovacuum_vacuum_cost_delay = 0)");

	$node->wait_for_log(
		qr/VacuumUpdateCosts\(db=\d+, rel=$relid, dobalance=no, cost_limit=\d+, cost_delay=0 active=no/,
		$offset);
	ok(1, "$testname: worker uses the new cost delay");

	ok( $node->poll_query_until(
			'postgres',
			"SELECT last_autovacuum IS NOT NULL FROM pg_stat_all_tables WHERE relid = $relid"
		),
		"$testname: autovacuum finished");
}

$node->append_conf('postgresql.conf', 'autovacuum = on');
$node->reload;

test_cost_change($heap, 'cost_heap', 'table');

# A TOAST table uses the storage parameter of its parent.
$node->safe_psql('postgres',
	"ALTER TABLE cost_toast SET (toast.autovacuum_enabled = true)");

test_cost_change($toast, 'cost_toast', 'TOAST table');

# Changing the parameters must not have canceled the workers.
ok( !$node->log_contains(qr/canceling autovacuum task/),
	'autovacuum was not canceled');

$node->stop;
done_testing();

# Disk spill of large transactions: capture must survive transactions
# larger than pg_undo.spill_threshold with bounded memory, and the
# spilled images must round-trip through undo.apply.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf(
	'postgresql.conf', q{
shared_preload_libraries = 'pg_undo'
wal_level = logical
max_replication_slots = 4
pg_undo.database = 'postgres'
pg_undo.naptime = 1
pg_undo.spill_threshold = 1
});
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_undo');
$node->poll_query_until('postgres', 'SELECT undo.ready()')
  or die 'pg_undo slot was not created';

$node->safe_psql('postgres',
	'CREATE TABLE big (id int PRIMARY KEY, pad text)');
$node->safe_psql('postgres', "SELECT undo.track('big')");

# one ~4.5MB transaction against a 1MB threshold
$node->safe_psql('postgres',
	"INSERT INTO big SELECT g, repeat('x', 200) FROM generate_series(1, 20000) g");

$node->poll_query_until('postgres',
	"SELECT count(*) = 20000 FROM undo.history WHERE relid = 'big'::regclass::oid")
  or die 'large transaction was not fully captured';

ok($node->log_contains('pg_undo: spilling transaction'),
	'transaction was spilled to disk');

# spilled images must restore the exact rows
my $xid = $node->safe_psql('postgres',
	"SELECT DISTINCT xid FROM undo.history WHERE relid = 'big'::regclass::oid");
is( $node->safe_psql('postgres', "SELECT * FROM undo.apply(xid => $xid)"),
	'20000|0|0',
	'undo of the spilled transaction applied all inverse operations');
is( $node->safe_psql('postgres', 'SELECT count(*) FROM big'),
	'0',
	'spilled INSERTs were undone');

# no spill files may remain once the cycle is done
is( $node->safe_psql(
		'postgres',
		"SELECT count(*) FROM pg_ls_dir('base/pgsql_tmp', true, false) f WHERE f LIKE '%pg_undo%'"),
	'0',
	'no leftover spill files');

done_testing();

# Disk spill of large transactions: capture must survive transactions
# larger than pg_undo.spill_threshold with bounded memory, and the
# spilled images (old and new) must round-trip through undo.apply.
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

# one ~1.4MB transaction against a 1MB threshold
$node->safe_psql('postgres',
	"INSERT INTO big SELECT g, repeat('x', 200) FROM generate_series(1, 6000) g");

$node->poll_query_until('postgres',
	"SELECT count(*) = 6000 FROM undo.history WHERE relid = 'big'::regclass::oid")
  or die 'large transaction was not fully captured';

ok($node->log_contains('pg_undo: spilling transaction'),
	'transaction was spilled to disk');

my $ins_xid = $node->safe_psql('postgres',
	"SELECT DISTINCT xid FROM undo.history WHERE relid = 'big'::regclass::oid");

# a spilled UPDATE carries both old and new images through the file
$node->safe_psql('postgres', "UPDATE big SET pad = repeat('z', 200)");
$node->poll_query_until('postgres',
	"SELECT count(*) = 12000 FROM undo.history WHERE relid = 'big'::regclass::oid")
  or die 'spilled UPDATE was not fully captured';

my $upd_xid = $node->safe_psql('postgres',
	"SELECT DISTINCT xid FROM undo.history WHERE relid = 'big'::regclass::oid AND op = 'U'");
is( $node->safe_psql('postgres', "SELECT * FROM undo.apply(xid => $upd_xid)"),
	'6000|0|0',
	'undo of the spilled UPDATE applied all inverse operations');
is( $node->safe_psql('postgres',
		"SELECT count(*) FROM big WHERE pad = repeat('x', 200)"),
	'6000',
	'old images restored from the spill file');

# the rows now match their insert images again, so the spilled INSERT
# transaction can be undone conflict-free
is( $node->safe_psql('postgres', "SELECT * FROM undo.apply(xid => $ins_xid)"),
	'6000|0|0',
	'undo of the spilled INSERT applied all inverse operations');
is( $node->safe_psql('postgres', 'SELECT count(*) FROM big'),
	'0',
	'spilled INSERTs were undone');

# once everything (including the undo of the undo-sized transactions,
# which spill as well) has been captured, no spill files may remain
$node->poll_query_until('postgres',
	"SELECT count(*) = 24000 FROM undo.history WHERE relid = 'big'::regclass::oid")
  or die 'undo transactions were not captured';
is( $node->safe_psql(
		'postgres',
		"SELECT count(*) FROM pg_ls_dir('base/pgsql_tmp', true, false) f WHERE f LIKE '%pg_undo%'"),
	'0',
	'no leftover spill files');

done_testing();

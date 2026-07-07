# Basic pg_undo test: capture, restart survival, undo.
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
});
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_undo');

# capture only covers changes made after the worker created its slot
$node->poll_query_until('postgres', 'SELECT undo.ready()')
  or die 'pg_undo slot was not created';

$node->safe_psql('postgres',
	'CREATE TABLE t (id int PRIMARY KEY, v text)');
$node->safe_psql('postgres', "SELECT undo.track('t')");

$node->safe_psql('postgres',
	"INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c')");
$node->safe_psql('postgres', "UPDATE t SET v = 'B' WHERE id = 2");
$node->safe_psql('postgres', 'DELETE FROM t');

# 3 inserts + 1 update + 3 deletes
$node->poll_query_until('postgres',
	'SELECT count(*) = 7 FROM undo.history')
  or die 'initial changes were not captured';

is( $node->safe_psql(
		'postgres', 'SELECT slot_name FROM pg_replication_slots'),
	'pg_undo',
	'replication slot exists');

# The slot and the dedupe logic must survive a restart without
# duplicating already-captured history.
$node->restart;

$node->safe_psql('postgres', "INSERT INTO t VALUES (10, 'post-restart')");
$node->poll_query_until('postgres',
	'SELECT count(*) = 8 FROM undo.history')
  or die 'capture did not resume after restart';

is( $node->safe_psql('postgres', 'SELECT count(*) FROM undo.history'),
	'8',
	'no duplicate history rows after restart');

# undo the mass DELETE only (xid-scoped)
my $del_xid = $node->safe_psql('postgres',
	"SELECT DISTINCT xid FROM undo.history WHERE op = 'D'");
my $result = $node->safe_psql('postgres',
	"SELECT * FROM undo.apply(xid => $del_xid)");
is($result, '3|0|0', 'undo of the DELETE applied 3 inverse operations');

is( $node->safe_psql(
		'postgres', "SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM t"),
	'1:a,2:B,3:c,10:post-restart',
	'deleted rows restored, later insert untouched');

done_testing();

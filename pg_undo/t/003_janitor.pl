# Janitor behavior: retention GC, the size failsafe (pause without WAL
# retention, automatic resume), trash GC, and crash recovery.
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
pg_undo.janitor_interval = 2
pg_undo.retention = '1 hour'
pg_undo.max_history_size = 1
});
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_undo');
$node->poll_query_until('postgres', 'SELECT undo.ready()')
  or die 'pg_undo slot was not created';

$node->safe_psql('postgres', 'CREATE TABLE t (id int PRIMARY KEY, pad text)');
$node->safe_psql('postgres', "SELECT undo.track('t')");

# blow through the 1MB failsafe
$node->safe_psql('postgres',
	"INSERT INTO t SELECT g, repeat('x', 200) FROM generate_series(1, 6000) g");
$node->poll_query_until('postgres',
	'SELECT capture_paused FROM undo.progress')
  or die 'failsafe did not pause capture';
ok($node->log_contains('pg_undo: history capture paused'),
	'pause was logged');

# while paused: history is frozen but the slot keeps advancing
my $frozen = $node->safe_psql('postgres', 'SELECT count(*) FROM undo.history');
my $cf1 = $node->safe_psql('postgres',
	"SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'pg_undo'");
$node->safe_psql('postgres',
	'INSERT INTO t SELECT g, NULL FROM generate_series(10001, 10100) g');
$node->poll_query_until('postgres',
	"SELECT confirmed_flush_lsn > '$cf1'::pg_lsn FROM pg_replication_slots WHERE slot_name = 'pg_undo'")
  or die 'slot did not advance while paused';
is( $node->safe_psql('postgres', 'SELECT count(*) FROM undo.history'),
	$frozen,
	'history is frozen while paused');

# retention GC empties the history, VACUUM reclaims the space, capture resumes
$node->safe_psql('postgres', "ALTER SYSTEM SET pg_undo.retention = '1 second'");
$node->reload;
$node->poll_query_until('postgres',
	'SELECT count(*) = 0 FROM undo.history')
  or die 'retention GC did not clean the history';
$node->safe_psql('postgres', 'VACUUM FULL undo.history');
$node->poll_query_until('postgres',
	'SELECT NOT capture_paused FROM undo.progress')
  or die 'capture did not resume';
ok($node->log_contains('pg_undo: history capture resumed'),
	'resume was logged');

# capture works again (put retention back first so GC stops racing us)
$node->safe_psql('postgres', "ALTER SYSTEM SET pg_undo.retention = '1 hour'");
$node->reload;
$node->safe_psql('postgres',
	'INSERT INTO t SELECT g, NULL FROM generate_series(20001, 20005) g');
$node->poll_query_until('postgres',
	'SELECT count(*) = 5 FROM undo.history')
  or die 'capture did not work after resume';

# crash recovery: immediate shutdown, then capture continues without dups
$node->stop('immediate');
$node->start;
$node->safe_psql('postgres',
	'INSERT INTO t SELECT g, NULL FROM generate_series(30001, 30003) g');
$node->poll_query_until('postgres',
	'SELECT count(*) = 8 FROM undo.history')
  or die 'capture did not resume after crash';
is( $node->safe_psql('postgres', 'SELECT count(*) FROM undo.history'),
	'8',
	'no duplicate history rows after a crash');

# trash GC
$node->safe_psql('postgres', "ALTER SYSTEM SET pg_undo.trash_retention = '1 second'");
$node->reload;
$node->safe_psql('postgres', 'CREATE TABLE doomed (id int)');
$node->safe_psql('postgres', 'DROP TABLE doomed');
is( $node->safe_psql('postgres',
		"SELECT count(*) FROM undo.trash_meta WHERE original_name = 'doomed'"),
	'1',
	'dropped table entered the recycle bin');
$node->poll_query_until('postgres',
	'SELECT count(*) = 0 FROM undo.trash_meta')
  or die 'trash GC did not purge the expired table';
ok($node->log_contains('pg_undo: purged expired table'),
	'trash purge was logged');

done_testing();

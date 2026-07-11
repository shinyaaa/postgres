# Copyright (c) 2026, PostgreSQL Global Development Group

# Test log_min_duration_statement_phases GUC: verifies that duration log
# entries triggered by log_min_duration_statement are restricted to the
# configured statement processing phases (parse, bind, execute).

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init();
$node->append_conf(
	'postgresql.conf', q{
log_min_duration_statement = 0
log_statement = 'none'
});
$node->start;

# With the default 'all', extended query protocol logs parse, bind, and
# execute durations.
note "default 'all' logs all phases";
my $log_offset = -s $node->logfile;
$node->psql('postgres', "SELECT 'phase_all' \\bind \\g");
ok( $node->log_contains(
		qr/duration: [0-9.]+ ms  parse <unnamed>: SELECT 'phase_all'/,
		$log_offset),
	"parse duration logged with 'all'");
ok( $node->log_contains(
		qr/duration: [0-9.]+ ms  bind <unnamed>: SELECT 'phase_all'/,
		$log_offset),
	"bind duration logged with 'all'");
ok( $node->log_contains(
		qr/duration: [0-9.]+ ms  execute <unnamed>: SELECT 'phase_all'/,
		$log_offset),
	"execute duration logged with 'all'");

# With 'parse, bind', the execute duration must not be logged.
note "'parse, bind' suppresses execute";
$log_offset = -s $node->logfile;
$node->psql(
	'postgres', "
	SET log_min_duration_statement_phases TO 'parse, bind';
	SELECT 'phase_pb' \\bind \\g
	SELECT 'pb_sentinel' \\parse stmt_sentinel");
$node->wait_for_log(qr/parse stmt_sentinel: SELECT 'pb_sentinel'/,
	$log_offset);
ok( $node->log_contains(
		qr/duration: [0-9.]+ ms  parse <unnamed>: SELECT 'phase_pb'/,
		$log_offset),
	"parse duration logged with 'parse, bind'");
ok( $node->log_contains(
		qr/duration: [0-9.]+ ms  bind <unnamed>: SELECT 'phase_pb'/,
		$log_offset),
	"bind duration logged with 'parse, bind'");
my $log = slurp_file($node->logfile, $log_offset);
unlike(
	$log,
	qr/duration: [0-9.]+ ms  execute <unnamed>: SELECT 'phase_pb'/,
	"execute duration not logged with 'parse, bind'");

# Simple query protocol counts as the execute phase, so it must not be
# logged with 'parse, bind' either.
note "simple query protocol counts as execute";
$log_offset = -s $node->logfile;
$node->psql(
	'postgres', "
	SET log_min_duration_statement_phases TO 'parse, bind';
	SELECT 'simple_pb';
	SELECT 'simple_sentinel' \\parse stmt_sentinel2");
$node->wait_for_log(qr/parse stmt_sentinel2: SELECT 'simple_sentinel'/,
	$log_offset);
$log = slurp_file($node->logfile, $log_offset);
unlike(
	$log,
	qr/duration: [0-9.]+ ms  statement: SELECT 'simple_pb'/,
	"simple query duration not logged with 'parse, bind'");

# With 'execute', parse and bind durations must not be logged, while
# execute and simple query durations are.
note "'execute' suppresses parse and bind";
$log_offset = -s $node->logfile;
$node->psql(
	'postgres', "
	SET log_min_duration_statement_phases TO 'execute';
	SELECT 'phase_exec' \\bind \\g
	SELECT 'simple_exec';");
$node->wait_for_log(qr/duration: [0-9.]+ ms  statement: SELECT 'simple_exec'/,
	$log_offset);
ok( $node->log_contains(
		qr/duration: [0-9.]+ ms  execute <unnamed>: SELECT 'phase_exec'/,
		$log_offset),
	"execute duration logged with 'execute'");
$log = slurp_file($node->logfile, $log_offset);
unlike(
	$log,
	qr/duration: [0-9.]+ ms  parse <unnamed>: SELECT 'phase_exec'/,
	"parse duration not logged with 'execute'");
unlike(
	$log,
	qr/duration: [0-9.]+ ms  bind <unnamed>: SELECT 'phase_exec'/,
	"bind duration not logged with 'execute'");

# Invalid values must be rejected.
note "invalid values are rejected";
my ($ret, $stdout, $stderr) = $node->psql('postgres',
	"SET log_min_duration_statement_phases TO 'foo'");
isnt($ret, 0, "unrecognized phase is rejected");
like(
	$stderr,
	qr/Unrecognized key word: "foo"/,
	"error message reports unrecognized key word");

($ret, $stdout, $stderr) = $node->psql('postgres',
	"SET log_min_duration_statement_phases TO ''");
isnt($ret, 0, "empty phase list is rejected");
like(
	$stderr,
	qr/Must specify at least one statement phase/,
	"error message reports empty phase list");

$node->stop;
done_testing();

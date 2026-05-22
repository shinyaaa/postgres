# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Validate that VACUUM logs explain why dead tuples could not be removed.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Set up a cluster
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init(allows_streaming => 'logical');
$node->append_conf('postgresql.conf', q[
max_prepared_transactions = 5
]);
$node->start;

# Create the hot standby test table and prepare backup/standby early, before
# any background psql sessions are started.  On Windows, background psql
# sessions that are terminated during earlier tests can leave file handles
# lingering, which causes pg_ctl start for the standby to fail.  By taking
# the backup and initializing the standby here, the standby start later only
# needs to launch pg_ctl after all those sessions have been fully cleaned up.
$node->backup('oldestxmin_hotstandby_bkp');
my $standby = PostgreSQL::Test::Cluster->new('oldestxmin_standby');
$standby->init_from_backup($node, 'oldestxmin_hotstandby_bkp',
	has_streaming => 1);
$standby->append_conf('postgresql.conf', q[
hot_standby_feedback = on
wal_receiver_status_interval = 100ms
]);


#
# Active statement
#
my $active_table = 'blocker_active';
$node->safe_psql('postgres', qq[
CREATE TABLE $active_table(id int);
INSERT INTO $active_table VALUES (0);
]);

my $blocker = $node->background_psql('postgres');
my $blocker_pid = $blocker->query_safe('SELECT pg_backend_pid();');
chomp($blocker_pid);

# Start a long-running query in the background that accesses a table
# This ensures xmin is set (pg_sleep alone doesn't require a snapshot)
$blocker->query_until(qr//, qq[
BEGIN;
SELECT * FROM $active_table, pg_sleep(60);
]);

# Wait for the blocker to have xmin set
$node->poll_query_until('postgres', qq[
SELECT backend_xmin IS NOT NULL
FROM pg_stat_activity
WHERE pid = $blocker_pid;
]);

$node->safe_psql('postgres', "DELETE FROM $active_table;");

my $stderr = '';
$node->psql('postgres', "VACUUM (VERBOSE) $active_table;", stderr => \$stderr);
like(
	$stderr,
	qr/oldest xmin blocker: active transaction holding snapshot \(pid = $blocker_pid\)/,
	'VACUUM VERBOSE reported active transaction holding snapshot as oldest xmin blocker');

# Cleanup
$node->safe_psql('postgres', qq[
SELECT pg_terminate_backend($blocker_pid);
DROP TABLE $active_table;
]);


#
# Idle in transaction
#
my $idle_table = 'blocker_idle';
$node->safe_psql('postgres', qq[
CREATE TABLE $idle_table(id int);
INSERT INTO $idle_table VALUES (0);
]);

my $idle_blocker = $node->background_psql('postgres');
my $idle_blocker_pid = $idle_blocker->query_safe('SELECT pg_backend_pid();');
chomp($idle_blocker_pid);

# Set isolation level to REPEATABLE READ to ensure xmin is set
$idle_blocker->query_safe(qq[
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT * FROM $idle_table;
]);

$node->safe_psql('postgres', "DELETE FROM $idle_table;");

$stderr = '';
$node->psql('postgres', "VACUUM (VERBOSE) $idle_table;", stderr => \$stderr);
like(
	$stderr,
	qr/oldest xmin blocker: idle in transaction holding snapshot \(pid = $idle_blocker_pid\)/,
	'VACUUM VERBOSE reported idle in transaction holding snapshot as oldest xmin blocker');

# Cleanup
$idle_blocker->quit;
$node->safe_psql('postgres', "DROP TABLE $idle_table;");


#
# Serializable transaction (idle in transaction)
#
my $serializable_table = 'blocker_serializable';
$node->safe_psql('postgres', qq[
CREATE TABLE $serializable_table(id int);
INSERT INTO $serializable_table VALUES (0);
]);

my $ser_blocker = $node->background_psql('postgres');
my $ser_blocker_pid = $ser_blocker->query_safe('SELECT pg_backend_pid();');
chomp($ser_blocker_pid);

$ser_blocker->query_safe(qq[
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT * FROM $serializable_table;
]);

$node->safe_psql('postgres', "DELETE FROM $serializable_table;");

$stderr = '';
$node->psql('postgres', "VACUUM (VERBOSE) $serializable_table;", stderr => \$stderr);
like(
	$stderr,
	qr/oldest xmin blocker: idle in transaction holding snapshot \(pid = $ser_blocker_pid\)/,
	'VACUUM VERBOSE reported serializable transaction as oldest xmin blocker');

# Cleanup
$ser_blocker->quit;
$node->safe_psql('postgres', "DROP TABLE $serializable_table;");


#
# Prefer xid owner over xmin match
#
my $prefer_table = 'blocker_prefer_xid_owner';
$node->safe_psql('postgres', qq[
CREATE TABLE $prefer_table(id int);
INSERT INTO $prefer_table VALUES (0);
]);

my $xid_owner = $node->background_psql('postgres');
my $xid_owner_pid = $xid_owner->query_safe('SELECT pg_backend_pid();');
chomp($xid_owner_pid);

$xid_owner->query_safe(qq[
BEGIN;
SELECT pg_current_xact_id();
]);

$node->poll_query_until('postgres', qq[
SELECT backend_xid IS NOT NULL
FROM pg_stat_activity
WHERE pid = $xid_owner_pid;
]);

my $owner_xid = $node->safe_psql('postgres', qq[
SELECT backend_xid
FROM pg_stat_activity
WHERE pid = $xid_owner_pid;
]);
chomp($owner_xid);

my $xmin_holder = $node->background_psql('postgres');
my $xmin_holder_pid = $xmin_holder->query_safe('SELECT pg_backend_pid();');
chomp($xmin_holder_pid);

# Start a long-running query that will take a snapshot after xid_owner begins
$xmin_holder->query_until(qr//, qq[
BEGIN;
SELECT * FROM $prefer_table, pg_sleep(60);
]);

# Ensure xmin_holder's xmin is held back by xid_owner
$node->poll_query_until('postgres', qq[
SELECT backend_xmin = '$owner_xid'::xid
FROM pg_stat_activity
WHERE pid = $xmin_holder_pid;
]);

$node->safe_psql('postgres', "DELETE FROM $prefer_table;");

$stderr = '';
$node->psql('postgres', "VACUUM (VERBOSE) $prefer_table;", stderr => \$stderr);
like(
	$stderr,
	qr/oldest xmin blocker: idle in transaction \(pid = $xid_owner_pid\)/,
	'VACUUM VERBOSE preferred xid owner over xmin match');

# Cleanup
$node->safe_psql('postgres', qq[
SELECT pg_terminate_backend($xmin_holder_pid);
SELECT pg_terminate_backend($xid_owner_pid);
DROP TABLE $prefer_table;
]);


#
# Prepared transaction
#
my $prepared_table = 'blocker_prepared';
$node->safe_psql('postgres', qq[
CREATE TABLE $prepared_table(id int);
INSERT INTO $prepared_table VALUES (0);
BEGIN;
PREPARE TRANSACTION 'gx_vacuum_xmin';
]);

$node->safe_psql('postgres', "DELETE FROM $prepared_table;");

$stderr = '';
$node->psql('postgres', "VACUUM (VERBOSE) $prepared_table;", stderr => \$stderr);
like(
	$stderr,
	qr/oldest xmin blocker: prepared transaction \(gid = gx_vacuum_xmin\)/,
	'VACUUM VERBOSE reported prepared transaction as oldest xmin blocker');

# Cleanup
$node->safe_psql('postgres', qq[
ROLLBACK PREPARED 'gx_vacuum_xmin';
DROP TABLE $prepared_table;
]);


#
# Logical replication slot
#
my $slot_table = 'blocker_slot';
$node->safe_psql('postgres', qq[
CREATE TABLE $slot_table(id int);
SELECT pg_create_logical_replication_slot('logical_slot', 'test_decoding');
DROP TABLE $slot_table;
]);

$stderr = '';
$node->psql('postgres', 'VACUUM (VERBOSE) pg_class;', stderr => \$stderr);
like(
	$stderr,
	qr/oldest xmin blocker: logical replication slot \(slot name = logical_slot\)/,
	'VACUUM VERBOSE reported logical replication slot as oldest xmin source');

# Cleanup
$node->safe_psql('postgres', qq[
SELECT pg_drop_replication_slot('logical_slot');
]);


#
# Hot standby feedback
#
# The standby was already initialized from a backup taken above.  Start it
# now, after all background psql sessions from earlier tests have been fully
# cleaned up.
my $hs_table = 'blocker_hotstandby';
$node->safe_psql('postgres', qq[
CREATE TABLE $hs_table(id int);
INSERT INTO $hs_table VALUES (0);
]);

$standby->start;
$node->wait_for_catchup($standby, 'replay', $node->lsn('flush'));

my $standby_reader = $standby->background_psql('postgres');
my $standby_reader_pid = $standby_reader->query_safe('SELECT pg_backend_pid();');
chomp($standby_reader_pid);

$standby_reader->query_until(qr//, qq[
BEGIN;
SELECT * FROM $hs_table, pg_sleep(60);
]);

# Wait for hot standby feedback to be sent
$node->poll_query_until('postgres', q[
SELECT backend_xmin IS NOT NULL
FROM pg_stat_replication
WHERE application_name = 'oldestxmin_standby';
]);

my $hs_blocker_pid = $node->safe_psql('postgres', q[
SELECT pid FROM pg_stat_replication
WHERE application_name = 'oldestxmin_standby';
]);
chomp($hs_blocker_pid);

$node->safe_psql('postgres', "DELETE FROM $hs_table;");

$stderr = '';
$node->psql('postgres', "VACUUM (VERBOSE) $hs_table;", stderr => \$stderr);
like(
	$stderr,
	qr/oldest xmin blocker: hot standby feedback \(standby name = oldestxmin_standby, pid = $hs_blocker_pid\)/,
	'VACUUM VERBOSE reported hot standby feedback as oldest xmin blocker');

# Cleanup
$standby->safe_psql('postgres', "SELECT pg_terminate_backend($standby_reader_pid);");
$node->safe_psql('postgres', "DROP TABLE $hs_table;");


$standby->stop;
$node->stop;
done_testing();

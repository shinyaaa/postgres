
# Copyright (c) 2026, PostgreSQL Global Development Group

# Test the XLH_INSERT_COMMON_HEADER optimization for heap_multi_insert WAL.
#
# Verifies that:
# 1. The common_header flag appears in pg_waldump output for COPY of
#    uniform tuples (all tuples share t_infomask2, t_infomask, t_hoff).
# 2. Data survives crash recovery when the common_header format is used.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->start;

# -----------------------------------------------------------
# Test 1: uniform tuples via COPY - common_header should be used
# -----------------------------------------------------------
$node->safe_psql('postgres',
	'CREATE TABLE test_uniform (a int, b int, c int)');

my $lsn_before = $node->safe_psql('postgres',
	'SELECT pg_current_wal_lsn()');

# COPY enough rows to ensure at least one multi-insert WAL record with
# ntuples > 1.  All tuples have the same structure (no NULLs, same column
# types), so they should share t_infomask2, t_infomask, and t_hoff.
$node->safe_psql('postgres', qq{
COPY test_uniform FROM STDIN;
1\t2\t3
4\t5\t6
7\t8\t9
10\t11\t12
13\t14\t15
16\t17\t18
19\t20\t21
22\t23\t24
25\t26\t27
28\t29\t30
\\.
});

my $lsn_after = $node->safe_psql('postgres',
	'SELECT pg_current_wal_lsn()');

# Use pg_waldump to inspect the WAL records between the two LSNs.
# The common_header flag should appear on MULTI_INSERT records for the
# user table data (and possibly catalog inserts too).
$node->command_checks_all(
	[
		'pg_waldump', '-p', $node->data_dir . '/pg_wal',
		'-s', $lsn_before, '-e', $lsn_after,
	],
	0,
	[qr/MULTI_INSERT.*common_header/],
	[],
	'common_header flag present in MULTI_INSERT WAL for uniform tuples');

# -----------------------------------------------------------
# Test 2: crash recovery with common_header WAL records
# -----------------------------------------------------------
$node->safe_psql('postgres',
	'CREATE TABLE test_recovery (id int, val text)');
$node->safe_psql('postgres', qq{
	INSERT INTO test_recovery
	SELECT g, 'row_' || g FROM generate_series(1, 5000) g;
});

my $count_before = $node->safe_psql('postgres',
	'SELECT count(*) FROM test_recovery');
my $sum_before = $node->safe_psql('postgres',
	'SELECT sum(id) FROM test_recovery');

# Simulate crash (immediate shutdown, no clean checkpoint)
$node->stop('immediate');

# Restart - WAL replay will occur, including common_header records
$node->start;

my $count_after = $node->safe_psql('postgres',
	'SELECT count(*) FROM test_recovery');
my $sum_after = $node->safe_psql('postgres',
	'SELECT sum(id) FROM test_recovery');

is($count_after, $count_before,
	'row count matches after crash recovery with common_header WAL');
is($sum_after, $sum_before,
	'data integrity preserved after crash recovery with common_header WAL');

# Clean up
$node->safe_psql('postgres', 'DROP TABLE test_uniform, test_recovery');
$node->stop;

done_testing();

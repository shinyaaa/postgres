# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Test WAL replay of multi-insert records whose tuple data was replaced by
# a conditional full-page image (wal_multi_insert_page_images), in both
# crash recovery and streaming replication, and the fallback shape produced
# when the image loses to poorly-compressible data.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1);
$primary->append_conf(
	'postgresql.conf', qq(
wal_compression = pglz
wal_multi_insert_page_images = on
autovacuum = off
));
$primary->start;

# Compressible load: repetitive text, so the compressed page image beats
# the tuple data and multi-insert records carry images.
my $compressible_rows =
  join("\n", map { "$_\trepetitive-payload-" . "x" x 200 } (1 .. 20000));
$primary->safe_psql('postgres',
	"CREATE TABLE img_tbl (id bigint, payload text);\n"
	  . "COPY img_tbl FROM STDIN;\n"
	  . $compressible_rows
	  . "\n\\.\n");

# Poorly-compressible load: random hex, so the conditional image loses and
# the records keep the per-tuple format (also exercises the back-off).
my @rand_lines;
for my $i (1 .. 5000)
{
	my $payload = join('', map { sprintf("%04x", int(rand(65536))) } (1 .. 60));
	push @rand_lines, "$i\t$payload";
}
$primary->safe_psql('postgres',
	"CREATE TABLE rand_tbl (id bigint, payload text);\n"
	  . "COPY rand_tbl FROM STDIN;\n"
	  . join("\n", @rand_lines)
	  . "\n\\.\n");

# COPY FREEZE onto images: covers the all-frozen VM interplay.
$primary->safe_psql('postgres',
	"CREATE TABLE frz_tbl (id bigint, payload text);\n"
	  . "BEGIN;\n"
	  . "TRUNCATE frz_tbl;\n"
	  . "COPY frz_tbl FROM STDIN (FREEZE);\n"
	  . $compressible_rows
	  . "\n\\.\n"
	  . "COMMIT;\n");

# The compressible load must have produced full-page images on the
# multi-insert records; pg_stat_wal counts them.
my $fpi = $primary->safe_psql('postgres', 'SELECT wal_fpi FROM pg_stat_wal');
cmp_ok($fpi, '>', 100, 'conditional page images were adopted');

my $sums_sql = q(
SELECT (SELECT md5(string_agg(id::text || payload, chr(10) ORDER BY id)) FROM img_tbl)
	|| '|' ||
	   (SELECT md5(string_agg(id::text || payload, chr(10) ORDER BY id)) FROM rand_tbl)
	|| '|' ||
	   (SELECT md5(string_agg(id::text || payload, chr(10) ORDER BY id)) FROM frz_tbl)
);
my $sums_before = $primary->safe_psql('postgres', $sums_sql);

# Streaming replication: a standby must replay both record shapes.
$primary->backup('bkp');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'bkp', has_streaming => 1);
$standby->start;
$primary->wait_for_replay_catchup($standby);
is( $standby->safe_psql('postgres', $sums_sql),
	$sums_before, 'standby replayed image and fallback records');
$standby->stop;

# Crash recovery: kill the primary and replay from the last checkpoint.
$primary->stop('immediate');
$primary->start;
is( $primary->safe_psql('postgres', $sums_sql),
	$sums_before, 'contents survive crash recovery');

# The tables must still be fully readable and the frozen table's rows
# visible (FREEZE bypasses normal visibility rules).
is( $primary->safe_psql('postgres', 'SELECT count(*) FROM frz_tbl'),
	'20000', 'frozen rows visible after crash recovery');

done_testing();

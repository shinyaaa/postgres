# Copyright (c) 2021-2026, PostgreSQL Global Development Group
#
# Check that combining backups with multiple jobs produces exactly the same
# result as combining them with one job, and that errors in a worker
# process are handled.

use strict;
use warnings FATAL => 'all';
use File::Compare;
use File::Find;
use File::Path qw(rmtree);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $tempdir = PostgreSQL::Test::Utils::tempdir_short();

# Can be changed to test the other modes.
my $mode = $ENV{PG_TEST_PG_COMBINEBACKUP_MODE} || '--copy';

note "testing using mode $mode";

# Set up a new database instance.
my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(has_archiving => 1, allows_streaming => 1);
$primary->append_conf('postgresql.conf', 'summarize_wal = on');
$primary->start;
my $tsprimary = $tempdir . '/ts';
mkdir($tsprimary) || die "mkdir $tsprimary: $!";

# Create enough tables that there is something for several workers to do,
# some of them in a tablespace so that pg_tblspc gets exercised too.
my $setup_sql = "CREATE TABLESPACE ts1 LOCATION '$tsprimary';\n";
for my $i (1 .. 40)
{
	my $ts = $i % 4 == 0 ? ' TABLESPACE ts1' : '';
	$setup_sql .=
	  "CREATE TABLE t$i (a int primary key, b text)$ts;\n"
	  . "INSERT INTO t$i SELECT g, md5(g::text) FROM generate_series(1, 200) g;\n";
}
$primary->safe_psql('postgres', $setup_sql);

# Take a full backup.
my $backup1path = $primary->backup_dir . '/backup1';
my $tsbackup1path = $primary->backup_dir . '/tsbackup1';
mkdir($tsbackup1path) || die "mkdir $tsbackup1path: $!";
$primary->command_ok(
	[
		'pg_basebackup',
		'--no-sync',
		'--pgdata' => $backup1path,
		'--checkpoint' => 'fast',
		'--tablespace-mapping' => "${tsprimary}=${tsbackup1path}"
	],
	"full backup");

# Modify some tables, including some in the tablespace, and take an
# incremental backup.
$primary->safe_psql('postgres', <<EOM);
UPDATE t1 SET b = 'changed' WHERE a < 50;
UPDATE t4 SET b = 'changed' WHERE a < 50;
INSERT INTO t2 SELECT g, 'new' FROM generate_series(201, 2000) g;
TRUNCATE t3;
DROP TABLE t5;
CREATE TABLE t_new (a int, b text);
INSERT INTO t_new VALUES (1, 'new table');
VACUUM;
EOM

my $backup2path = $primary->backup_dir . '/backup2';
my $tsbackup2path = $primary->backup_dir . '/tsbackup2';
mkdir($tsbackup2path) || die "mkdir $tsbackup2path: $!";
$primary->command_ok(
	[
		'pg_basebackup',
		'--no-sync',
		'--pgdata' => $backup2path,
		'--checkpoint' => 'fast',
		'--tablespace-mapping' => "${tsprimary}=${tsbackup2path}",
		'--incremental' => $backup1path . '/backup_manifest'
	],
	"incremental backup");

# Modify a few more and take a second incremental backup, so that
# reconstruction has to consult a chain of prior backups.
$primary->safe_psql('postgres', <<EOM);
UPDATE t1 SET b = 'changed again' WHERE a < 10;
UPDATE t8 SET b = 'changed' WHERE a < 50;
INSERT INTO t_new VALUES (2, 'second row');
VACUUM;
EOM

my $backup3path = $primary->backup_dir . '/backup3';
my $tsbackup3path = $primary->backup_dir . '/tsbackup3';
mkdir($tsbackup3path) || die "mkdir $tsbackup3path: $!";
$primary->command_ok(
	[
		'pg_basebackup',
		'--no-sync',
		'--pgdata' => $backup3path,
		'--checkpoint' => 'fast',
		'--tablespace-mapping' => "${tsprimary}=${tsbackup3path}",
		'--incremental' => $backup2path . '/backup_manifest'
	],
	"second incremental backup");

$primary->stop;

# The outputs must be on the same file system as the backups, so that the
# --copy-file-range and --link modes work; tempdir_short may be elsewhere.
my $outroot = $primary->backup_dir;

# Combine the backups with a single job and with several, into separate
# output directories.
my %outputs;
for my $jobs (1, 4)
{
	my $outpath = $outroot . "/out$jobs";
	my $tsoutpath = $outroot . "/tsout$jobs";
	$outputs{$jobs} = { path => $outpath, tspath => $tsoutpath };
	command_ok(
		[
			'pg_combinebackup', $mode,
			'--jobs' => $jobs,
			'--output' => $outpath,
			'--tablespace-mapping' => "${tsbackup3path}=${tsoutpath}",
			$backup1path, $backup2path, $backup3path
		],
		"combine backups with $jobs job(s)");
}

# Every file that one run produced must exist in the other, with identical
# contents. The only exception is the backup manifest, whose entries record
# the mtime of each output file (and whose own checksum covers those), so
# compare it with the mtimes masked out.
sub compare_trees
{
	my ($dir1, $dir2, $what) = @_;
	my @files;

	find(
		{
			wanted => sub { push @files, $File::Find::name if -f $_; },
			no_chdir => 1
		},
		$dir1);

	my $ndiff = 0;
	for my $file1 (sort @files)
	{
		my $file2 = $file1;
		$file2 =~ s/^\Q$dir1\E/$dir2/;

		if ($file1 =~ m{/backup_manifest$})
		{
			my $m1 = slurp_file($file1);
			my $m2 = slurp_file($file2);
			s/"Last-Modified": "[^"]*"//g for ($m1, $m2);
			s/"Manifest-Checksum": "[^"]*"//g for ($m1, $m2);
			if ($m1 ne $m2)
			{
				diag("manifests differ: $file1 and $file2");
				$ndiff++;
			}
		}
		elsif (compare($file1, $file2) != 0)
		{
			diag("files differ: $file1 and $file2");
			$ndiff++;
		}
	}
	is($ndiff, 0, "$what: all files match");
	return scalar(@files);
}

my $nfiles1 =
  compare_trees($outputs{1}{path}, $outputs{4}{path}, "1 vs 4 jobs");
my $nfiles4 =
  compare_trees($outputs{4}{path}, $outputs{1}{path}, "4 vs 1 jobs");
is($nfiles4, $nfiles1, "same number of files with 1 and 4 jobs");
ok($nfiles1 > 100, "output has a reasonable number of files ($nfiles1)");
compare_trees($outputs{1}{tspath}, $outputs{4}{tspath},
	"tablespace, 1 vs 4 jobs");
compare_trees($outputs{4}{tspath}, $outputs{1}{tspath},
	"tablespace, 4 vs 1 jobs");

# The manifest written with 4 jobs must describe the files correctly.
command_ok([ 'pg_verifybackup', '--quiet', $outputs{4}{path} ],
	'output of parallel combine verifies');

# Dry run with jobs must not create anything.
command_ok(
	[
		'pg_combinebackup', $mode,
		'--jobs' => 4,
		'--dry-run',
		'--output' => $outroot . '/dryrun',
		'--tablespace-mapping' => "${tsbackup3path}=${outroot}/tsdryrun",
		$backup1path, $backup2path, $backup3path
	],
	'dry run with jobs succeeds');
ok(!-e $outroot . '/dryrun', 'dry run with jobs creates no output');

# Bogus job counts are rejected.
command_fails_like(
	[
		'pg_combinebackup', '--jobs' => 0,
		'--output' => $outroot . '/never',
		$backup1path, $backup2path, $backup3path
	],
	qr/-j\/--jobs must be in range/,
	'--jobs=0 is rejected');

# A failure in a worker must fail the whole operation and remove the output
# directory. Provoke one by removing a file from the full backup that an
# incremental file in the last backup relies on.
my @incrementals;
find(
	{
		wanted => sub {
			push @incrementals, $File::Find::name
			  if -f $_ && m{/INCREMENTAL\.\d+$};
		},
		no_chdir => 1
	},
	$backup3path . '/base');
ok(scalar(@incrementals) > 0, 'found an incremental file to break');
my $victim = $incrementals[0];
$victim =~ s/^\Q$backup3path\E/$backup1path/;
$victim =~ s{/INCREMENTAL\.(\d+)$}{/$1};
unlink($victim) || die "unlink $victim: $!";

my $brokenpath = $outroot . '/broken';
command_fails_like(
	[
		'pg_combinebackup', $mode,
		'--jobs' => 4,
		'--output' => $brokenpath,
		'--tablespace-mapping' => "${tsbackup3path}=${outroot}/tsbroken",
		$backup1path, $backup2path, $backup3path
	],
	qr/could not open file|worker process exited unexpectedly/,
	'failure in a worker is reported');

SKIP:
{
	# On Windows, the workers are threads, and the ones still running when
	# the failing one exits the process can race against the removal of the
	# output directory.
	skip 'directory removal racy on Windows', 1 if $windows_os;
	ok(!-e $brokenpath, 'output directory removed after worker failure');
}

done_testing();

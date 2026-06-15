use Test2::V0;
# Phase 2 UI inlining: drive a REAL captured event log through the inlined
# importer (App::Yath2::Schema::Importer -> RunProcessor) against an ephemeral
# SQLite database, and assert the resulting rows match the fixture.

use strict;
use warnings;

BEGIN {
    # The schema driver must be loaded before anything pulls in the overlays.
    $ENV{YATH_DB_SCHEMA} = 'SQLite';
}

use File::Spec;
use File::Temp qw/tempdir/;

# --- Dependency gate -------------------------------------------------------
BEGIN {
    eval { require DBD::SQLite;                       1 } or plan skip_all => "DBD::SQLite required: $@";
    eval { require DBIx::Class;                       1 } or plan skip_all => "DBIx::Class required: $@";
    eval { require DateTime::Format::SQLite;          1 } or plan skip_all => "DateTime::Format::SQLite required: $@";
    eval { require DBIx::Class::InflateColumn::Serializer::JSON; 1 } or plan skip_all => "InflateColumn::Serializer::JSON required: $@";
}

# Locate the fixture + schema sql relative to this test, so it works from any cwd.
my $here = __FILE__;
my ($vol, $dir) = File::Spec->splitpath($here);
# t/AI/unit/ -> repo root is three levels up
my $root = File::Spec->rel2abs(File::Spec->catdir($dir, File::Spec->updir, File::Spec->updir, File::Spec->updir));

my $fixture = File::Spec->catfile($root, qw/t AI fixtures ui sample-run.jsonl/);
my $sqlfile = File::Spec->catfile($root, qw/share schema SQLite.sql/);

plan skip_all => "fixture not found: $fixture" unless -f $fixture;
plan skip_all => "schema sql not found: $sqlfile" unless -f $sqlfile;

# --- Build an ephemeral SQLite DB + deploy the schema ----------------------
my $tmp    = tempdir(CLEANUP => 1);
my $dbpath = File::Spec->catfile($tmp, 'test.db');
my $dsn    = "dbi:SQLite:dbname=$dbpath";

require DBI;
my $now = sub { my @t = localtime; sprintf("%04d-%02d-%02d %02d:%02d:%02d", 1900 + $t[5], 1 + $t[4], @t[3, 2, 1, 0]) };

{
    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, AutoCommit => 1, sqlite_allow_multiple_statements => 1});
    $dbh->sqlite_create_function('now', 0, $now);
    open(my $fh, '<', $sqlfile) or die "Could not open $sqlfile: $!";
    local $/;
    my $sql = <$fh>;
    $dbh->do($sql);
    $dbh->disconnect;
}

# --- Connect the inlined schema via Config ---------------------------------
require App::Yath2::Schema::SQLite;
require App::Yath2::Schema::Config;

my $config = App::Yath2::Schema::Config->new(
    dbi_dsn  => $dsn,
    dbi_user => '',
    dbi_pass => '',
);

my $schema = $config->schema;

# Register the SQLite 'now' default-function on the live DBIC handle too.
$schema->storage->dbh->sqlite_create_function('now', 0, $now);
$schema->storage->dbh_do(sub { $_[1]->sqlite_create_function('now', 0, $now) });

ok($schema, "connected inlined App::Yath2::Schema to ephemeral SQLite");

# --- Pre-create the Run row (Importer::process_log expects a Run) -----------
my $project = $schema->resultset('Project')->create({name => 'Test2-Harness'});
my $user    = $schema->resultset('User')->create({username => 'fixture-user', role => 'user'});

use Test2::Util::UUID qw/gen_uuid/;
my $run_uuid = gen_uuid();

my $run = $schema->resultset('Run')->create({
    run_uuid   => $run_uuid,
    canon      => 1,
    mode       => 'complete',
    status     => 'pending',
    user_id    => $user->user_id,
    project_id => $project->project_id,
});

ok($run, "created Run row");

# --- Drive the log through the importer -------------------------------------
require App::Yath2::Schema::Importer;

open(my $logfh, '<', $fixture) or die "Could not open fixture: $!";

my $importer = App::Yath2::Schema::Importer->new(config => $config);
my $status;
my $ok = eval { $status = $importer->process_log($run, $logfh); 1 };
my $err = $@;
ok($ok, "process_log completed without dying") or diag($err);
close($logfh);

$run->discard_changes;

# --- Assertions on the resulting rows --------------------------------------

# Run status should be 'complete' after a clean import.
is($run->status, 'complete', "run marked complete after import");

# Exactly one real test job plus the harness-internal (job0) log job.
my @jobs = $schema->resultset('Job')->search({run_id => $run->run_id})->all;
ok(@jobs >= 1, "at least one Job row created (got " . scalar(@jobs) . ")");

my @real_jobs     = grep { !$_->is_harness_out } @jobs;
my @harness_jobs  = grep { $_->is_harness_out } @jobs;

is(scalar(@real_jobs), 1, "exactly one real (non-harness-out) Job row");

my $job = $real_jobs[0];

# The fixture's job is fixture.tx and it FAILED (top-level + subtest failure).
my $file = $job->test_file->filename;
like($file, qr/fixture\.tx$/, "job's test file is fixture.tx (got: $file)");

# Job try assertions: it failed.
my @tries = $schema->resultset('JobTry')->search({job_id => $job->job_id})->all;
is(scalar(@tries), 1, "one JobTry for the job");
my $try = $tries[0];
is($try->fail,   1,          "job try recorded as failed");
is($try->status, 'complete', "job try status complete");

# Event rows must have been written.
my $event_count = $schema->resultset('Event')->search({job_try_id => $try->job_try_id})->count;
ok($event_count > 0, "Event rows written for the job try (got $event_count)");

# Subtest events: the fixture has two subtests (one pass, one fail).
my $subtest_events = $schema->resultset('Event')->search({job_try_id => $try->job_try_id, is_subtest => 1})->count;
ok($subtest_events >= 2, "at least two subtest events recorded (got $subtest_events)");

# Diag/fail events present.
my $diag_events = $schema->resultset('Event')->search({job_try_id => $try->job_try_id, is_diag => 1})->count;
ok($diag_events > 0, "diagnostic events recorded (got $diag_events)");

# Job-try fields: the fixture carries harness_job_fields (mem_rss/size/peak).
my $field_count = $schema->resultset('JobTryField')->search({job_try_id => $try->job_try_id})->count;
ok($field_count >= 3, "job try fields recorded from harness_job_fields (got $field_count)");

my @field_names = sort map { $_->name } $schema->resultset('JobTryField')->search({job_try_id => $try->job_try_id})->all;
ok((grep { $_ eq 'mem_rss' } @field_names), "mem_rss field present");

# Duration should have been derived (from harness_job_end.times.total).
ok(defined($try->duration) && $try->duration > 0, "job try duration derived from times.total (got " . ($try->duration // 'undef') . ")");

# At least one Event has rendered output (Composer ran).
my $rendered_count = $schema->resultset('Event')->search(
    {job_try_id => $try->job_try_id, rendered => {'!=' => undef}}
)->count;
ok($rendered_count > 0, "Composer produced rendered output on events (got $rendered_count)");

done_testing;

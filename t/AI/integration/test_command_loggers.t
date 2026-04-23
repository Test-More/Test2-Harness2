use Test2::V0;

use File::Spec ();
BEGIN { @INC = map { File::Spec->rel2abs($_) } @INC }

use File::Temp qw/tempdir/;

use App::Yath2::Command::test;

package Fake::Workspace;
sub new           { bless { workdir => $_[1] }, $_[0] }
sub workdir       { $_[0]->{workdir} }
sub create_option { }

package Fake::Settings;
sub new       { bless { workspace => $_[1] }, $_[0] }
sub workspace { $_[0]->{workspace} }

package main;

my $tmp = tempdir(CLEANUP => 1);
my $tf  = "$tmp/quick.t";
open my $fh, '>', $tf or die $!;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

my $work = "$tmp/work";
mkdir $work or die $!;

my $cmd = App::Yath2::Command::test->new(
    args     => [$tf],
    settings => Fake::Settings->new(Fake::Workspace->new($work)),
);

# Suppress the "Work directory: ..." line on stdout so prove output stays clean.
my $captured = '';
{
    open(my $cap, '>', \$captured) or die $!;
    my $orig = select $cap;
    my $rc   = $cmd->run;
    select $orig;
    is($rc, 0, 'test command exits 0 on a passing test');
}

ok(-f "$work/logs/services/harness.jsonl", 'harness JSONL logger emitted file');
ok(-f "$work/logs/services/harness.json",  'harness JSON  logger emitted file');

my @per_job_jsonl = glob "$work/logs/runs/*/tests/*.jsonl";
my @per_job_json  = glob "$work/logs/runs/*/tests/*.json";
ok(scalar(@per_job_jsonl), 'per-job JSONL logger emitted at least one file');
ok(scalar(@per_job_json),  'per-job JSON  logger emitted at least one file');

ok(-f "$work/logs/artifacts.json", 'global artifacts manifest written');
my @run_manifests = glob "$work/logs/runs/*/artifacts.json";
is(scalar(@run_manifests), 1, 'one per-run artifacts manifest written');

done_testing;

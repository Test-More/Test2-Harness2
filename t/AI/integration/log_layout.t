use Test2::V0;

use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::SpawnRace qw/finish_and_wait/;

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

# Post-new_log_refactor on-disk layout: per-run files live under
# logs/runs/<run_id>/, with the standard collector trio plus jobs/
# subdirs:
#
#   spec.jsonl.zst    -- one row per collector startup
#   events.jsonl.zst  -- pipeline output, append-only
#   report.jsonl.zst  -- one row per shutdown
#
# state.json is gone (the run service emits state via in-stream
# events; the collector folds the final state into report.jsonl.zst
# on exit).

my $dir = tempdir(CLEANUP => 1);

my $tf_path = "$dir/ok.t";
open my $fh, '>', $tf_path or die $!;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

my $spawn = Test2::Harness2->spawn(workdir => $dir);

my $q = $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf_path)]);
ok($q->{ok}, 'queued') or diag explain $q;

wait_until(
    sub {
        my $s = $spawn->status;
        return !@{$s->{queue}} && !@{$s->{running} // []};
    },
    15,
) or die "run did not drain";

finish_and_wait($spawn);

# Inspect logs/runs/<run_id>/.
opendir my $rdh, "$dir/logs/runs" or die "open $dir/logs/runs: $!";
my @run_dirs = grep { !/^\./ && -d "$dir/logs/runs/$_" } readdir $rdh;
closedir $rdh;

is(scalar @run_dirs, 1, 'exactly one run directory under logs/runs/');
my $run_id = $run_dirs[0];
my $rundir = "$dir/logs/runs/$run_id";

# Standard collector trio at the run base.
ok(-e "$rundir/spec.jsonl.zst" || -e "$rundir/spec.jsonl",
    'spec.jsonl(.zst) at run base');
ok(-e "$rundir/events.jsonl.zst" || -e "$rundir/events.jsonl",
    'events.jsonl(.zst) at run base');
ok(-e "$rundir/report.jsonl.zst" || -e "$rundir/report.jsonl",
    'report.jsonl(.zst) at run base');

# state.json must NOT exist (removed in new_log_refactor).
ok(!-e "$rundir/state.json",     'no state.json');
ok(!-e "$rundir/state.json.zst", 'no state.json.zst');

# Legacy basenames must not exist either.
ok(!-e "$dir/logs/runs/$run_id.json",      'no legacy runs/<run_id>.json sibling');
ok(!-e "$dir/logs/runs/$run_id.jsonl",     'no legacy runs/<run_id>.jsonl sibling');

done_testing;

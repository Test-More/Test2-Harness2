use Test2::V0;

use File::Temp qw/tempfile/;

use App::Yath2::Tester qw/yath/;
use Test2::Harness2::Util::JSON qw/encode_json/;

# Regression for #124: `yath failed` on a log from an interrupted run (Ctrl-C,
# CI cancellation, OOM kill) where a failing job recorded a failing subtest but
# never emitted a harness_job_end. Before the fix, reaching $ends->[-1]->{...}
# on the empty ends array died with "Modification of non-creatable array value
# attempted, subscript -1" -- crashing the very command used to inspect such
# logs, in BOTH the default table mode and the --brief mode (where the die
# happened inside the `if` condition itself).

# Two jobs:
#  NORMAL  - a failing job with a harness_job_end (normal path still works).
#  ABORTED - a failing subtest but NO harness_job_end (the interrupted case).
my @events = (
    {stamp => 1, job_id => 'NORMAL', facet_data => {harness_job_end => {fail => 1, rel_file => 't/normalfail.t'}}},
    {
        stamp      => 2,
        job_id     => 'ABORTED',
        facet_data => {
            trace  => {nested => 0, frame => ['main', 't/aborted.t', 5]},
            parent => {children => []},
            assert => {pass => 0, details => 'a failing subtest before the run was killed'},
        },
    },
);

my ($fh, $logfile) = tempfile("failed-aborted-$$-XXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.jsonl');
print $fh encode_json($_), "\n" for @events;
close($fh);

# Default (table) mode: must not crash, must list the aborted failure with
# N/A file and Times Run 0, and still list the normal failure.
yath(
    command => 'failed',
    args    => [$logfile],
    env     => {TABLE_TERM_SIZE => 1000, TS_TERM_SIZE => 1000},
    exit    => 0,
    test    => sub {
        my $out = shift;

        ok(!$out->{exit}, "'failed' exits 0 on a log with an endless failing job");
        unlike($out->{output}, qr/non-creatable array value/, "no autovivification crash");

        like($out->{output}, qr/\bABORTED\b/, "endless failing job is listed");
        like($out->{output}, qr/N\/A/, "endless job renders 'N/A' for its missing test file");
        like($out->{output}, qr/a failing subtest before the run was killed/, "the recorded failing subtest is shown");
        like($out->{output}, qr/\bNORMAL\b/, "job with a harness_job_end is still listed");
        like($out->{output}, qr/t\/normalfail\.t/, "normal job's test file is shown");
    },
);

# --brief mode: the die used to happen in the `if` condition even for jobs that
# would print nothing. Now it must not crash; the endless job (no rel_file)
# prints nothing while the normal failure's file is still printed.
yath(
    command => 'failed',
    args    => ['--brief', $logfile],
    exit    => 0,
    test    => sub {
        my $out = shift;

        ok(!$out->{exit}, "'failed --brief' exits 0 on a log with an endless failing job");
        unlike($out->{output}, qr/non-creatable array value/, "no autovivification crash in brief mode");
        like($out->{output}, qr/t\/normalfail\.t/, "brief mode prints the normal failure's file");
    },
);

done_testing;

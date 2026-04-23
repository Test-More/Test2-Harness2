use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Harness2::MiniHarness;
use Test2::Harness2::Util::JSON qw/decode_json/;

# Resolve the path to this test file's location so we can build paths to
# selftest files regardless of the working directory.
my $t_dir    = File::Spec->catdir(File::Spec->rel2abs(File::Spec->curdir()), 't');
my $selftest = File::Spec->catdir($t_dir,                                    'selftest');

# Helper: read all JSONL events from a log file.
sub read_events {
    my ($log_file) = @_;
    open(my $fh, '<', $log_file) or die "Cannot open $log_file: $!";
    my @events;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my $ok  = eval { push @events, decode_json($line); 1 };
        my $err = $@;
        die "Bad JSON in log: $err\nLine: $line\n" unless $ok;
    }
    close $fh;
    return @events;
}

# ---------------------------------------------------------------------------
# Test 1: One-liner style usage — simple.t (2 ok() calls)
# ---------------------------------------------------------------------------

subtest 'simple.t passes end-to-end' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $simple  = File::Spec->catfile($selftest, 'simple.t');

    plan skip_all => "selftest/simple.t not found" unless -f $simple;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $simple,
        log_dir   => $log_dir,
        includes  => ['lib'],
    );

    ok($result->passed, 'result->passed is true');

    my $log_file = $result->log_file;
    ok(-f $log_file, 'JSONL log file exists');
    ok(-s $log_file, 'JSONL log file is non-empty');

    my @events = read_events($log_file);
    ok(scalar(@events) > 0, 'log file has events');

    # All events must have a stamp.
    for my $e (@events) {
        ok(defined $e->{stamp}, "event has stamp")
            or note explain($e);
    }

    # Collect assert events.
    my @asserts = grep { defined $_->{facet_data} && defined $_->{facet_data}{assert} } @events;
    is(scalar(@asserts), 2, 'log has exactly 2 assert events (simple.t has 2 ok() calls)');

    # Check plan event.
    my @plans = grep { defined $_->{facet_data} && defined $_->{facet_data}{plan} } @events;
    ok(scalar(@plans) >= 1, 'log has at least one plan event');
};

# ---------------------------------------------------------------------------
# Test 2: TAP-only test — tap_only.t (3 assertions, all lines are raw TAP)
# ---------------------------------------------------------------------------

subtest 'tap_only.t passes with from_tap facet' => sub {
    my $log_dir  = tempdir(CLEANUP => 1);
    my $tap_only = File::Spec->catfile($selftest, 'tap_only.t');

    plan skip_all => "selftest/tap_only.t not found" unless -f $tap_only;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $tap_only,
        log_dir   => $log_dir,
    );

    ok($result->passed, 'result->passed is true for tap_only.t');

    my @events = read_events($result->log_file);
    ok(scalar(@events) > 0, 'log file has events');

    # Collect assert events.
    my @asserts = grep { defined $_->{facet_data} && defined $_->{facet_data}{assert} } @events;
    is(scalar(@asserts), 3, 'log has 3 assert events');

    # All assert events must have from_tap facet (TAP parser processed them).
    for my $e (@asserts) {
        ok(
            defined $e->{facet_data}{from_tap},
            'assert event has from_tap facet'
        ) or note explain($e->{facet_data});
    }
};

# ---------------------------------------------------------------------------
# Test 3: Exit code propagation — a test that dies
# ---------------------------------------------------------------------------

subtest 'failing test: not passed, non-zero exit' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $tmp_dir = tempdir(CLEANUP => 1);

    # Write a test that dies immediately.
    my $die_test = File::Spec->catfile($tmp_dir, 'dying.t');
    open(my $fh, '>', $die_test) or die "Cannot write $die_test: $!";
    print $fh "use strict;\nuse warnings;\ndie 'intentional death';\n";
    close $fh;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $die_test,
        log_dir   => $log_dir,
    );

    ok(!$result->passed,        'result->passed is false for dying test');
    ok($result->exit_code != 0, "exit_code is non-zero (got " . $result->exit_code . ")");
};

# ---------------------------------------------------------------------------
# Test 4: Custom env vars — test reads $ENV{MY_TEST_VAR}
# ---------------------------------------------------------------------------

subtest 'custom env vars are passed to child' => sub {
    my $log_dir = tempdir(CLEANUP => 1);
    my $tmp_dir = tempdir(CLEANUP => 1);

    # Write a test that verifies MY_TEST_VAR is set to 'hello'.
    my $env_test = File::Spec->catfile($tmp_dir, 'env_check.t');
    open(my $fh, '>', $env_test) or die "Cannot write $env_test: $!";
    print $fh <<'END_TEST';
use strict;
use warnings;
use Test2::V0;
is($ENV{MY_TEST_VAR}, 'hello', 'MY_TEST_VAR is set correctly');
done_testing;
END_TEST
    close $fh;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $env_test,
        log_dir   => $log_dir,
        includes  => ['lib'],
        env       => {MY_TEST_VAR => 'hello'},
    );

    ok($result->passed, 'result->passed is true when env var is correct');
};

done_testing;

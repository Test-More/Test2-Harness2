use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Test2::Harness2::Util::JSON qw/decode_json/;

my $driver = File::Spec->rel2abs(
    File::Spec->catfile(File::Spec->curdir, 't', 'scripts', 'collector'),
);
ok(-x $driver, 'driver is executable');

sub _slurp_lines {
    my ($path) = @_;
    return () unless -e $path;
    open(my $fh, '<', $path) or die "open $path: $!";
    my @lines = <$fh>;
    close($fh);
    chomp @lines;
    return @lines;
}

sub _run_driver {
    my (%opts) = @_;
    my $dir  = $opts{dir};
    my @args = (
        $driver,
        '--dir',      $dir,
        '--parser',   $opts{parser}   || 'Test2::Harness2::Collector::Parser::IOParser',
        '--recorder', $opts{recorder} || 'Test2::Harness2::Collector::Recorder::Files',
        ($opts{auditor} ? ('--auditor', $opts{auditor}) : ()),
        ($opts{type}    ? ('--type',    $opts{type})    : ()),
        (defined $opts{orphan_timeout}   ? ('--orphan-timeout',   $opts{orphan_timeout})   : ()),
        (defined $opts{silence_timeout}  ? ('--silence-timeout',  $opts{silence_timeout})  : ()),
        (defined $opts{lifetime_timeout} ? ('--lifetime-timeout', $opts{lifetime_timeout}) : ()),
        '--',
        @{$opts{exec}},
    );

    my $status = system($^X, @args);
    return $status;
}

subtest io_parser_plain_run => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $status = _run_driver(
        dir  => $dir,
        exec => [$^X, '-E', 'say "hello world"; warn "diag line\n"'],
    );
    is($status, 0, 'collector exited cleanly');

    my @events = map { decode_json($_) } _slurp_lines(File::Spec->catfile($dir, 'events.jsonl'));

    my ($stdout) = grep { ($_->{facet_data}{from_stream}{source} // '') eq 'STDOUT' } @events;
    ok($stdout, 'STDOUT event captured');
    is($stdout->{facet_data}{from_stream}{details}, 'hello world');

    my ($stderr) = grep { ($_->{facet_data}{from_stream}{source} // '') eq 'STDERR' } @events;
    ok($stderr, 'STDERR event captured');

    my ($exit_line) = _slurp_lines(File::Spec->catfile($dir, 'exit'));
    is($exit_line, '0', 'exit recorded as 0');

    ok(-e File::Spec->catfile($dir, 'finalized'), 'finalized marker present');
};

subtest tap_parser_with_auditor_passing => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $status = _run_driver(
        dir      => $dir,
        parser   => 'Test2::Harness2::Collector::Parser::TAPParser',
        auditor  => 'Test2::Harness2::Collector::Auditor::Test',
        exec     => [
            $^X, '-Ilib',
            '-e',
'$ENV{T2_FORMATTER}="Stream2"; use Test2::Tools::Basic qw/ok done_testing/; ok(1, "first"); ok(1, "second"); done_testing();',
        ],
    );
    is($status, 0, 'passing test exits 0');

    my @states = map { decode_json($_) } _slurp_lines(File::Spec->catfile($dir, 'state.jsonl'));
    my @kinds  = map { $_->{state} } @states;
    is($kinds[0],  'starting',  'first state is starting');
    is($kinds[-1], 'completed', 'last state is completed');

    my @events = map { decode_json($_) } _slurp_lines(File::Spec->catfile($dir, 'events.jsonl'));
    my @asserts = grep { $_->{facet_data}{assert} } @events;
    ok(scalar(@asserts) >= 2, 'at least two assert events captured');

    my ($exit_line) = _slurp_lines(File::Spec->catfile($dir, 'exit'));
    is($exit_line, '0');
};

subtest non_zero_exit_propagates => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $status = _run_driver(
        dir  => $dir,
        exec => [$^X, '-e', 'exit 3'],
    );
    is(($status >> 8), 3, 'collector mirrors child exit=3');

    my ($exit_line) = _slurp_lines(File::Spec->catfile($dir, 'exit'));
    ok($exit_line, 'exit file populated');

    my $wait = $exit_line + 0;
    is(($wait >> 8), 3, 'exit file holds wait-status with exit=3');
};

subtest failing_tap_test => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $status = _run_driver(
        dir      => $dir,
        parser   => 'Test2::Harness2::Collector::Parser::TAPParser',
        auditor  => 'Test2::Harness2::Collector::Auditor::Test',
        exec     => [
            $^X, '-Ilib',
            '-e',
'$ENV{T2_FORMATTER}="Stream2"; use Test2::Tools::Basic qw/ok done_testing/; ok(1, "pass"); ok(0, "fail"); done_testing();',
        ],
    );
    isnt(($status >> 8), 0, 'failing test exits non-zero');

    my @states = map { decode_json($_) } _slurp_lines(File::Spec->catfile($dir, 'state.jsonl'));
    my @kinds  = map { $_->{state} } @states;
    ok((grep { $_ eq 'failing' } @kinds), 'failing state recorded')
        or note(explain(\@kinds));
};

subtest orphan_descendants_trigger_timeout => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Parent exits immediately. Grandchild inherits STDOUT/STDERR and
    # sleeps long enough that, with a tiny orphan_timeout, the collector
    # must trip the watchdog rather than wait for EOF.
    my $script = <<'PERL';
my $pid = fork // die "fork: $!";
if ($pid) {
    exit 0;
}
sleep 5;
exit 0;
PERL

    my $started = time();
    my $status  = _run_driver(
        dir            => $dir,
        exec           => [$^X, '-e', $script],
        orphan_timeout => 1,
    );
    my $elapsed = time() - $started;

    is(($status >> 8), 0, 'collector mirrors parent exit=0');
    ok($elapsed < 4, "collector returned before grandchild exited (elapsed ${elapsed}s)")
        or diag "expected < 4s, got ${elapsed}s";

    ok(-e File::Spec->catfile($dir, 'orphaned'),  'orphaned marker present');
    ok(-e File::Spec->catfile($dir, 'finalized'), 'finalized marker present');

    my @events = map { decode_json($_) } _slurp_lines(File::Spec->catfile($dir, 'events.jsonl'));
    my ($orphan_event) = grep { $_->{facet_data}{harness_orphan} } @events;
    ok($orphan_event, 'harness_orphan synthetic event recorded');
    is($orphan_event->{facet_data}{harness_orphan}{quiet_seconds}, 1, 'event carries the timeout used');

    my ($info) = grep { $_->{tag} eq 'ORPHAN' } @{ $orphan_event->{facet_data}{info} // [] };
    ok($info, 'ORPHAN info facet attached');
};

subtest silence_timeout_kills_quiet_test => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Test prints once, then sleeps long enough that the silence
    # timeout fires before sleep returns.
    my $script = 'print "alive\n"; STDOUT->flush; sleep 30; exit 0;';

    my $started = time();
    _run_driver(
        dir             => $dir,
        exec            => [$^X, '-e', $script],
        silence_timeout => 1,
    );
    my $elapsed = time() - $started;

    ok($elapsed < 10, "collector killed the test before sleep returned (elapsed ${elapsed}s)")
        or diag "expected < 10s, got ${elapsed}s";

    my ($exit_line) = _slurp_lines(File::Spec->catfile($dir, 'exit'));
    my $wait_status = $exit_line + 0;
    ok(($wait_status & 0x7f), "child wait-status carries a signal (raw=${wait_status})");

    ok(-e File::Spec->catfile($dir, 'timed_out'), 'timed_out marker present');
    my ($marker) = _slurp_lines(File::Spec->catfile($dir, 'timed_out'));
    like($marker, qr/^silence /, 'marker identifies kind=silence');

    my @events = map { decode_json($_) } _slurp_lines(File::Spec->catfile($dir, 'events.jsonl'));
    my ($t_event) = grep { ($_->{facet_data}{harness_timeout} // {})->{kind} } @events;
    ok($t_event, 'harness_timeout event recorded');
    is($t_event->{facet_data}{harness_timeout}{kind}, 'silence', 'event carries kind=silence');

    my @errors = map { @{ $_->{facet_data}{errors} // [] } } @events;
    ok((grep { $_->{tag} eq 'TIMEOUT' && $_->{fail} } @errors), 'TIMEOUT fail-error attached');
};

subtest lifetime_timeout_kills_chatty_test => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Test that never goes silent: prints frequently for a long time.
    # Silence timeout would not save us; only lifetime does.
    my $script = 'use Time::HiRes qw/sleep/;'
        . ' STDOUT->autoflush(1); for (1..100) { print "tick $_\n"; sleep 0.1 }';

    my $started = time();
    _run_driver(
        dir              => $dir,
        exec             => [$^X, '-e', $script],
        lifetime_timeout => 1,
    );
    my $elapsed = time() - $started;

    ok($elapsed < 8, "collector killed chatty test before its loop finished (elapsed ${elapsed}s)")
        or diag "expected < 8s, got ${elapsed}s";

    my ($exit_line) = _slurp_lines(File::Spec->catfile($dir, 'exit'));
    my $wait_status = $exit_line + 0;
    ok(($wait_status & 0x7f), "child wait-status carries a signal (raw=${wait_status})");

    ok(-e File::Spec->catfile($dir, 'timed_out'), 'timed_out marker present');
    my ($marker) = _slurp_lines(File::Spec->catfile($dir, 'timed_out'));
    like($marker, qr/^lifetime /, 'marker identifies kind=lifetime');

    my @events = map { decode_json($_) } _slurp_lines(File::Spec->catfile($dir, 'events.jsonl'));
    my ($t_event) = grep { ($_->{facet_data}{harness_timeout} // {})->{kind} } @events;
    is($t_event->{facet_data}{harness_timeout}{kind}, 'lifetime', 'event carries kind=lifetime');
};

subtest silence_timeout_ignored_for_services => sub {
    my $dir = tempdir(CLEANUP => 1);

    # 'service' type — silence timeout must be ignored. Long sleep
    # with no output: should NOT be killed.
    my $script = 'print "starting\n"; STDOUT->flush; sleep 2; exit 0;';

    my $status = _run_driver(
        dir             => $dir,
        type            => 'service',
        silence_timeout => 1,
        exec            => [$^X, '-e', $script],
    );

    is(($status >> 8), 0, 'service ran to completion despite silence');
    ok(!-e File::Spec->catfile($dir, 'timed_out'), 'no timed_out marker for service');
};

subtest no_orphan_marker_on_clean_run => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $status = _run_driver(
        dir            => $dir,
        exec           => [$^X, '-E', 'say "ok"'],
        orphan_timeout => 1,
    );
    is(($status >> 8), 0, 'clean run');
    ok(!-e File::Spec->catfile($dir, 'orphaned'), 'no orphaned marker on clean run');
};

done_testing;

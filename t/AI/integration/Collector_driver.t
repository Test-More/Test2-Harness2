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

done_testing;

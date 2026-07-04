use Test2::V0;
use feature 'signatures';
no warnings 'experimental::signatures';

use File::Temp qw/tempdir/;
use IO::Compress::Gzip qw/gzip/;

use Test2::Harness2::Util::File::JSONL;

use App::Yath2::RenderLoop;
use App::Yath2::RenderLoop::JSONLFileProducer;

# Regression coverage for TODO-147 (replay bundle):
#   * finding 53: a job-filtered replay must not treat a batch that read events
#     off disk but filtered them all out as an idle poll (no backoff sleep).
#   * G7: replaying a truncated .jsonl.gz (killed writer) must not crash with the
#     internal 'cannot seek backwards' error -- it should surface the decodable
#     prefix and finish so the command reaches its incomplete-log diagnostic,
#     exactly like a truncated PLAIN log.
#   * G9: the producer must record which filter args actually selected a job so
#     the command can warn about filter args that matched nothing.
#   * G10: a single corrupt (mid-file) line must not abort the whole replay; it
#     is warned about and skipped, and the valid events still render.

{
    package StubSink;
    sub new          { bless {events => []}, shift }
    sub render_event { push @{$_[0]{events}} => $_[1]; return }
    sub step         { }
    sub finish       { $_[0]{finished}++ }
    sub events       { @{$_[0]{events}} }
}

my $settings = mock {} => (add => [check_group => sub { 0 }]);

# A recorded log: a run header, two jobs (one pass one fail), and the run rollup.
sub log_records () {
    return (
        {job_id => 0,          facet_data => {harness_run => {run_id => 'RUN-1'}}},
        {job_id => 'JOB-PASS', facet_data => {harness_job_queued => {file => 't/pass.t', rel_file => 't/pass.t'}}},
        {job_id => 'JOB-PASS', facet_data => {harness_job_launch => {}}},
        {job_id => 'JOB-PASS', facet_data => {assert => {pass => 1, number => 1, details => 'p'}}},
        {job_id => 'JOB-PASS', facet_data => {harness_job_end => {file => 't/pass.t', rel_file => 't/pass.t', fail => 0}}},
        {job_id => 'JOB-FAIL', facet_data => {harness_job_queued => {file => 't/fail.t', rel_file => 't/fail.t'}}},
        {job_id => 'JOB-FAIL', facet_data => {harness_job_launch => {}}},
        {job_id => 'JOB-FAIL', facet_data => {assert => {pass => 0, number => 1, details => 'f'}}},
        {job_id => 'JOB-FAIL', facet_data => {harness_job_end => {file => 't/fail.t', rel_file => 't/fail.t', fail => 1}}},
        {job_id => 0,          facet_data => {harness_final => {pass => 0, failed => [['JOB-FAIL', 't/fail.t']]}}},
    );
}

sub write_log ($path) {
    Test2::Harness2::Util::File::JSONL->new(name => $path)->write(log_records());
    return;
}

sub run_loop ($producer) {
    my $sink = StubSink->new;
    my $sleeps = 0;
    my $loop = App::Yath2::RenderLoop->new(
        renderers => [$sink],
        producer  => $producer,
        settings  => $settings,
        run_id    => 'RUN-1',
    );
    {
        no warnings 'redefine';
        local *App::Yath2::RenderLoop::sleep = sub { $sleeps++ };
        $loop->start;
    }
    $loop->finish;
    return ($loop, $sink, $sleeps);
}

subtest 'finding 53: filtered-out batches are not idle (no backoff sleep)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/log.jsonl";
    write_log($log);

    # Filter matches nothing: every rendered event in the (single) raw batch is
    # dropped, so poll() returns () even though it made real forward progress.
    my $producer = App::Yath2::RenderLoop::JSONLFileProducer->new(
        log_file => $log,
        jobs     => {'JOB-NOPE' => 1},
    );

    my ($loop, $sink, $sleeps) = run_loop($producer);

    ok($loop->done, "loop ran to completion");
    is($sleeps, 0, "no idle backoff sleeps charged for a fully-filtered batch (would be >=1 before the fix)");
    is([$sink->events], [], "no events rendered under a non-matching filter");
    is($loop->final_data->{pass}, 0, "recorded rollup still captured");
    isa_ok($producer, ['App::Yath2::RenderLoop::JSONLFileProducer']);
    can_ok($producer, 'idle');
    is($producer->idle, 1, "producer idle() true once the raw stream is exhausted");
};

subtest 'G9: matched records which filter args selected a job' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/log.jsonl";
    write_log($log);

    # A job-id arg (JOB-PASS) that matches, a file-path arg (t/fail.t) that
    # matches via _match_job, and a bogus arg (missing.t) that matches nothing.
    my $producer = App::Yath2::RenderLoop::JSONLFileProducer->new(
        log_file => $log,
        jobs     => {'JOB-PASS' => 1, 't/fail.t' => 1, 'missing.t' => 1},
    );

    run_loop($producer);

    my $matched = $producer->matched;
    ok($matched->{'JOB-PASS'}, "job-id filter arg recorded as matched");
    ok($matched->{'t/fail.t'}, "file-path filter arg recorded as matched");
    ok(!$matched->{'missing.t'}, "unmatched filter arg is detectable (never marked)");
};

subtest 'G7: truncated .jsonl.gz replays cleanly (no cannot-seek-backwards crash)' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $plain = "$dir/log.jsonl";
    write_log($plain);
    my $body = Test2::Harness2::Util::read_file($plain);

    my $gz = "$dir/log.jsonl.gz";
    gzip(\$body, $gz) or die "gzip failed";
    truncate($gz, int((-s $gz) * 0.6)) or die "truncate gz: $!";

    my $producer = App::Yath2::RenderLoop::JSONLFileProducer->new(log_file => $gz);

    my ($loop, $sink);
    my $ok = eval { ($loop, $sink) = run_loop($producer); 1 };
    my $err = $@;

    ok($ok, "truncated gzip replay did NOT die") or diag($err);
    ok($loop->done, "loop reached completion on the truncated gzip");
    ok(scalar($sink->events) > 0, "the decodable prefix of the truncated gzip was still rendered");
    is($loop->final_data, undef, "no harness_final in the truncated log -> command emits 'Log did not contain final data!'");
};

subtest 'G7 parity: a truncated PLAIN .jsonl behaves the same (no final data, no die)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $plain = "$dir/log.jsonl";
    write_log($plain);
    truncate($plain, int((-s $plain) * 0.6)) or die "truncate plain: $!";

    my $producer = App::Yath2::RenderLoop::JSONLFileProducer->new(log_file => $plain);

    my ($loop, $sink);
    my $warnings = warnings {
        my $ok = eval { ($loop, $sink) = run_loop($producer); 1 };
        ok($ok, "truncated plain replay did NOT die") or diag($@);
    };

    ok($loop->done, "loop reached completion on the truncated plain log");
    is($loop->final_data, undef, "truncated plain log also has no final data (parity with gzip)");
};

subtest 'G10: a single corrupt line is skipped with a warning, replay completes' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/log.jsonl";

    # Write a valid log, then splice a corrupt (undecodable) line into the middle.
    write_log($log);
    my $body = Test2::Harness2::Util::read_file($log);
    my @lines = split /\n/, $body;
    splice(@lines, 3, 0, 'THIS IS NOT JSON');
    Test2::Harness2::Util::write_file($log, join("\n", @lines) . "\n");

    my $producer = App::Yath2::RenderLoop::JSONLFileProducer->new(log_file => $log);

    my ($loop, $sink);
    my $warnings = warnings {
        my $ok = eval { ($loop, $sink) = run_loop($producer); 1 };
        ok($ok, "corrupt-line replay did NOT die (skip_bad_decode => 2)") or diag($@);
    };

    like($warnings, [qr/failed to decode/], "warned about the corrupt line");
    ok($loop->done, "loop completed despite the corrupt line");
    is($loop->final_data->{pass}, 0, "valid events (including the recorded rollup) still processed");

    my %seen;
    for my $e ($sink->events) { $seen{$_}++ for keys %{$e->{facet_data}} }
    ok($seen{harness_job_end}, "events after the corrupt line still rendered");
};

done_testing;

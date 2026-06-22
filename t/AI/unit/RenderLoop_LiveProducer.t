use Test2::V0;
use feature 'signatures';
no warnings 'experimental::signatures';
use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;

use Test2::Collector::Event;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Renderer::Driver;

use App::Yath2::RenderLoop;
use App::Yath2::RenderLoop::LiveProducer;

# The LiveProducer wraps a Renderer::Driver in COLLECT mode (its dispatch is
# redirected into the producer's queue) so poll() is a pure source; App::Yath2::RenderLoop
# owns the dispatch fan-out + the sink lifecycle. This verifies:
#   * a live run renders end-to-end through the loop
#   * the per-job rollup (final_data) + tallies come back through the loop
#   * the false-FAIL fix is PRESERVED: the Driver's bounded events-file terminal
#     wait still settles a passing job's TRUE verdict even when the `completed`
#     transition beats the events file's terminal flush

{
    package StubSink;
    sub new          { bless {events => []}, shift }
    sub render_event { push @{$_[0]{events}} => $_[1]; return }
    sub step         { }
    sub finish       { $_[0]{finished}++ }
    sub finished     { $_[0]{finished} // 0 }
    sub events       { @{$_[0]{events}} }
}

my $ev = sub { bless({facet_data => {@_}}, 'Test2::Collector::Event') };

my $settings = mock {} => (add => [check_group => sub { 0 }]);

sub build_loop ($mon, $sub, $tasks) {
    my $sink = StubSink->new;

    my $driver = Test2::Harness2::Renderer::Driver->new(
        settings  => $settings,
        renderers => [],          # collect-only: the loop owns the fan-out
        run_id    => 'RUN-1',
        tasks     => $tasks,
    );

    my $producer = App::Yath2::RenderLoop::LiveProducer->new(
        engine     => $driver,
        subscriber => $sub,
        monitor    => $mon,
        done_check => sub { $mon->{__done} ? 1 : 0 },
    );

    my $loop = App::Yath2::RenderLoop->new(
        renderers => [$sink],
        producer  => $producer,
        settings  => $settings,
        run_id    => 'RUN-1',
    );

    return ($loop, $sink, $producer);
}

subtest passing_run => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/pass-events.jsonl.zst";

    my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
    $rec->record_event($ev->(assert => {pass => 1, number => 1, details => 'a'}));
    $rec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 1}));
    $rec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
    $rec->finalize;

    my $mon  = Test2::Harness2::Runner::Monitor->new;
    my $uuid = 'UUID-PASS';
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid, name => 't/pass.t', events_file => $file, run_uuid => 'RUN-1', try => 0}, harness_state_transition => {state => 'starting'}}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_final_state => {pass => 1}}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_state_transition => {state => 'completed'}}});
    $mon->{__done} = 1;    # source exhausted (socket would be closed)

    my ($loop, $sink) = build_loop($mon, undef, [{job_id => 'JOB-PASS', file => 't/pass.t', rel_file => 't/pass.t'}]);

    $loop->start;
    $loop->finish;

    my ($end) = grep { $_->facet_data->{harness_job_end} } $sink->events;
    ok($end, "a harness_job_end was rendered");
    is($end->facet_data->{harness_job_end}{fail}, 0, "passing job rendered fail=0");

    is($loop->final_data->{pass}, 1, "run rollup PASSED");
    ok(!$loop->final_data->{failed}, "nothing failed");
    is($loop->tests_seen, 1, "one test launched");
    is($loop->asserts_seen, 1, "one assertion seen via the loop fan-out");
    is($sink->finished, 1, "sink finish() called once");
};

subtest verdict_race_preserved => sub {
    # Regression for the completed-before-final-state false-FAIL, now through the
    # RenderLoop + LiveProducer. The events file is short of its terminal when the
    # `completed` transition fires; a background writer appends the passing
    # terminal a moment later. The reused Driver bounded-waits and settles TRUE.
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/pass-events.jsonl.zst";

    my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
    $rec->record_event($ev->(assert => {pass => 1, number => 1, details => 'a'}));
    # do NOT finalize: leave the file short of its terminal.

    my $mon  = Test2::Harness2::Runner::Monitor->new;
    my $uuid = 'UUID-PASS';
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid, name => 't/pass.t', events_file => $file, run_uuid => 'RUN-1', try => 0}, harness_state_transition => {state => 'starting'}}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_state_transition => {state => 'completed'}}});
    $mon->{__done} = 1;

    ok(!$mon->collector($uuid)->{final_state}, "final_state NOT folded yet (completed first)");

    my ($loop, $sink) = build_loop($mon, undef, [{job_id => 'JOB-PASS', file => 't/pass.t', rel_file => 't/pass.t'}]);

    my $pid = fork // die "fork: $!";
    unless ($pid) {
        sleep 0.15;
        $rec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 1}));
        $rec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
        $rec->finalize;
        exit 0;
    }

    my $start = time;
    $loop->start;
    waitpid($pid, 0);

    ok((time - $start) >= 0.1, "the loop bounded-waited for the events-file terminal");

    my ($end) = grep { $_->facet_data->{harness_job_end} } $sink->events;
    ok($end, "a harness_job_end was rendered");
    is($end->facet_data->{harness_job_end}{fail}, 0, "PASSING job rendered fail=0 (NOT prematurely FAILED)");

    is($loop->final_data->{pass}, 1, "run rollup PASSED");
    ok(!$loop->final_data->{failed}, "no failed jobs in rollup");
};

done_testing;

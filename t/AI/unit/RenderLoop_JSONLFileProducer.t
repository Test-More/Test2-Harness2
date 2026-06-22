use Test2::V0;
use feature 'signatures';
no warnings 'experimental::signatures';
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::File::JSONL;

use App::Yath2::RenderLoop;
use App::Yath2::RenderLoop::JSONLFileProducer;

# The JSONLFileProducer is a PURE source over a flat .jsonl log; App::Yath2::RenderLoop
# owns the dispatch fan-out. Together they replay a recorded run (the replay path)
# through the same loop the live commands use. This exercises:
#   * poll() yields the recorded events in file order
#   * the recorded harness_final is captured for final_data (not re-rendered)
#   * tests_seen / asserts_seen are tallied
#   * the optional job filter limits which jobs render
#   * the loop fans the events out to the sink renderers

{
    package StubSink;
    sub new          { bless {events => []}, shift }
    sub render_event { push @{$_[0]{events}} => $_[1]; return }
    sub step         { }
    sub finish       { $_[0]{finished}++ }
    sub finished     { $_[0]{finished} // 0 }
    sub events       { @{$_[0]{events}} }
}

# A recorded log: a run header, two jobs (one pass one fail), and the run rollup.
sub write_log ($path) {
    my $jsonl = Test2::Harness2::Util::File::JSONL->new(name => $path);
    $jsonl->write(
        {job_id => 0, facet_data => {harness_run => {run_id => 'RUN-1'}}},
        {job_id => 'JOB-PASS', facet_data => {harness_job_queued => {file => 't/pass.t', rel_file => 't/pass.t'}}},
        {job_id => 'JOB-PASS', facet_data => {harness_job_launch => {}}},
        {job_id => 'JOB-PASS', facet_data => {assert => {pass => 1, number => 1, details => 'p'}}},
        {job_id => 'JOB-PASS', facet_data => {harness_job_end => {file => 't/pass.t', rel_file => 't/pass.t', fail => 0}}},
        {job_id => 'JOB-FAIL', facet_data => {harness_job_queued => {file => 't/fail.t', rel_file => 't/fail.t'}}},
        {job_id => 'JOB-FAIL', facet_data => {harness_job_launch => {}}},
        {job_id => 'JOB-FAIL', facet_data => {assert => {pass => 0, number => 1, details => 'f'}}},
        {job_id => 'JOB-FAIL', facet_data => {harness_job_end => {file => 't/fail.t', rel_file => 't/fail.t', fail => 1}}},
        {job_id => 0, facet_data => {harness_final => {pass => 0, failed => [['JOB-FAIL', 't/fail.t']]}}},
    );
    return;
}

my $settings = mock {} => (add => [check_group => sub { 0 }]);

subtest full_replay => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/log.jsonl";
    write_log($log);

    my $producer = App::Yath2::RenderLoop::JSONLFileProducer->new(log_file => $log);
    my $sink     = StubSink->new;

    my $loop = App::Yath2::RenderLoop->new(
        renderers => [$sink],
        producer  => $producer,
        settings  => $settings,
        run_id    => 'RUN-1',
    );

    $loop->start;
    $loop->finish;

    ok($loop->done, "loop ran to completion");

    my %seen;
    for my $e ($sink->events) {
        $seen{$_}++ for keys %{$e->{facet_data}};
    }

    ok($seen{harness_run},       "harness_run was rendered");
    ok($seen{assert},            "assert events were rendered");
    ok($seen{harness_job_end},   "harness_job_end events were rendered");
    ok(!$seen{harness_final},    "harness_final was captured, NOT re-rendered");

    is($loop->final_data, {pass => 0, failed => [['JOB-FAIL', 't/fail.t']]}, "final_data is the recorded rollup");
    is($loop->tests_seen, 2, "two tests launched");
    is($loop->asserts_seen, 2, "two assertions seen");
    is($sink->finished, 1, "sink finish() was called once");
};

subtest job_filter => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/log.jsonl";
    write_log($log);

    my $producer = App::Yath2::RenderLoop::JSONLFileProducer->new(
        log_file => $log,
        jobs     => {'JOB-PASS' => 1},
    );
    my $sink = StubSink->new;

    my $loop = App::Yath2::RenderLoop->new(
        renderers => [$sink],
        producer  => $producer,
        settings  => $settings,
        run_id    => 'RUN-1',
    );

    $loop->start;

    my %job_ids;
    for my $e ($sink->events) {
        next unless $e->{job_id};
        $job_ids{$e->{job_id}}++;
    }

    ok($job_ids{'JOB-PASS'}, "filtered-in job rendered");
    ok(!$job_ids{'JOB-FAIL'}, "filtered-out job did NOT render");
    is($loop->final_data->{pass}, 0, "recorded rollup still captured under a filter");
};

done_testing;

use Test2::V0;
use feature 'signatures';
no warnings 'experimental::signatures';
use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;

use Test2::Collector::Event;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::Event;
use Test2::Harness2::JobReader;
use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Renderer::Driver;

use App::Yath2::RenderLoop::LiveProducer;

# Regression bundle for ticket #141 (renderer Driver / live-pipeline). Each
# subtest pins one of the audited defects.

my $settings = mock {} => (add => [check_group => sub { 0 }]);
my $ev = sub { bless({facet_data => {@_}}, 'Test2::Collector::Event') };

sub new_driver (%extra) {
    my @events;
    my $driver = Test2::Harness2::Renderer::Driver->new(
        settings    => $settings,
        run_id      => 'RUN-1',
        dispatch_cb => sub { push @events => $_[0] },
        %extra,
    );
    return ($driver, \@events);
}

# ---------------------------------------------------------------------------
# (4) A job whose collector already launched, then the runner watchdog aborts
# it, must NOT be counted twice: exactly one launch, tests_seen==1, and no
# phantom "Times Run: 2 / Succeeded Eventually? NO" retried row.
# ---------------------------------------------------------------------------
subtest aborted_after_launch_not_double_counted => sub {
    my ($driver, $events) = new_driver(
        tasks => [{job_id => 'JOB-X', file => 't/x.t', rel_file => 't/x.t', is_try => 1}],
    );

    my $mon = Test2::Harness2::Runner::Monitor->new;
    $mon->feed({facet_data => {harness_collector => {uuid => 'UUID-X', name => 't/x.t', run_uuid => 'RUN-1', try => 1}, harness_state_transition => {state => 'starting'}}});
    $mon->feed({facet_data => {harness_runner_job => {job_id => 'JOB-X', file => 't/x.t', state => 'aborted', details => 'watchdog aborted'}}});

    $driver->step($mon);

    is($driver->tests_seen, 1, "launched-then-aborted job counted exactly once");

    my @launches = grep { $_->facet_data->{harness_job_launch} } @$events;
    is(scalar(@launches), 1, "exactly one launch rendered (no phantom second launch/started line)");

    my @ends = grep { $_->facet_data->{harness_job_end} } @$events;
    is(scalar(@ends), 1, "one aborted harness_job_end rendered");
    is($ends[0]->facet_data->{harness_job_end}{aborted}, 1, "the end is flagged aborted");

    $driver->finalize($mon);
    my $final = $driver->final_data;

    ok(!$final->{retried}, "no phantom retried row for a launched-then-aborted job");
    is($final->{failed}, [['JOB-X', 't/x.t']], "aborted job listed as failed once");
    is($final->{pass}, 0, "run rollup is a failure");
};

# ---------------------------------------------------------------------------
# (99) harness_job_launch.retry is a BOOLEAN keyed off the 1-based try ordinal:
# a first attempt (try==1) is LAUNCH (retry 0), a retry (try==2) is RETRY
# (retry 1). Previously the raw ordinal was emitted, tagging every first launch
# RETRY.
# ---------------------------------------------------------------------------
subtest launch_retry_flag_is_boolean => sub {
    my ($driver, $events) = new_driver(
        tasks => [{job_id => 'JOB-A', file => 't/a.t', rel_file => 't/a.t', is_try => 1}],
    );

    my $mon = Test2::Harness2::Runner::Monitor->new;
    # First attempt: try == 1.
    $mon->feed({facet_data => {harness_collector => {uuid => 'U1', name => 't/a.t', run_uuid => 'RUN-1', try => 1}, harness_state_transition => {state => 'starting'}}});
    $driver->step($mon);

    # A retry of the same file is a NEW collector carrying try == 2.
    $mon->feed({facet_data => {harness_collector => {uuid => 'U2', name => 't/a.t', run_uuid => 'RUN-1', try => 2}, harness_state_transition => {state => 'starting'}}});
    $driver->step($mon);

    my @launches = grep { $_->facet_data->{harness_job_launch} } @$events;
    is(scalar(@launches), 2, "two launches rendered (first attempt + retry)");
    is($launches[0]->facet_data->{harness_job_launch}{retry}, 0, "first attempt retry flag 0 (LAUNCH)");
    is($launches[1]->facet_data->{harness_job_launch}{retry}, 1, "retry attempt retry flag 1 (RETRY)");

    # is_try carries the ordinal itself, untouched.
    is($launches[0]->facet_data->{harness_job}{is_try}, 1, "first launch is_try ordinal is 1");
    is($launches[1]->facet_data->{harness_job}{is_try}, 2, "retry launch is_try ordinal is 2");
};

# The aborted path must also emit a boolean retry flag (0 for a first attempt),
# not the old hardcoded try=0-that-was-fine-but-inverse; a first aborted attempt
# is LAUNCH, not RETRY.
subtest aborted_first_attempt_tagged_launch => sub {
    my ($driver, $events) = new_driver(
        tasks => [{job_id => 'JOB-Z', file => 't/z.t', rel_file => 't/z.t', is_try => 1}],
    );

    my $mon = Test2::Harness2::Runner::Monitor->new;
    # Never launched (no collector) -- straight to aborted.
    $mon->feed({facet_data => {harness_runner_job => {job_id => 'JOB-Z', file => 't/z.t', state => 'aborted'}}});
    $driver->step($mon);

    my ($launch) = grep { $_->facet_data->{harness_job_launch} } @$events;
    ok($launch, "an unlaunched aborted job synthesizes its launch");
    is($launch->facet_data->{harness_job_launch}{retry}, 0, "first-attempt aborted launch tagged LAUNCH (retry 0)");
    is($driver->tests_seen, 1, "unlaunched aborted job counted once");
};

# ---------------------------------------------------------------------------
# (99, formatter side) The formatter maps the boolean retry flag to LAUNCH /
# RETRY. Exercised through the real renderer with a captured inner formatter.
# ---------------------------------------------------------------------------
subtest formatter_launch_retry_tag => sub {
    require Getopt::Yath::Settings;
    require Test2::Harness2::Renderer::Formatter;

    open(my $out, '>', \my $obuf) or die "open scalar: $!";
    open(my $err, '>', \my $ebuf) or die "open scalar: $!";

    my $fset = Getopt::Yath::Settings->new(
        display => {verbose => 1, color => 0, no_wrap => 0},
        debug   => {interactive => 0},
    );
    my $cmd = mock {} => (add => [group => sub { 'test' }]);

    my $fmt = Test2::Harness2::Renderer::Formatter->new(
        settings        => $fset,
        command_class   => $cmd,
        show_job_launch => 1,
        io              => $out,
        io_err          => $err,
    );

    # Swap the real inner formatter for a stub that captures the mutated facet
    # data the renderer computed (info tags included).
    my @writes;
    $fmt->{formatter} = mock {} => (add => [write => sub { push @writes => $_[3]; return }]);

    my $tag_for = sub ($retry) {
        @writes = ();
        my $e = Test2::Harness2::Event->new(
            stamp => time, job_id => 'J', job_try => 1, event_id => 'E', run_id => 'R',
            facet_data => {
                harness_job        => {job_id => 'J', file => 't/a.t'},
                harness_job_launch => {retry => $retry},
            },
        );
        $fmt->render_event($e);
        my ($f) = @writes;
        my ($info) = grep { ($_->{tag} // '') =~ /^(LAUNCH|RETRY)$/ } @{$f->{info} // []};
        return $info ? $info->{tag} : undef;
    };

    is($tag_for->(0), 'LAUNCH', "retry flag 0 -> LAUNCH tag");
    is($tag_for->(1), 'RETRY',  "retry flag 1 -> RETRY tag");
};

# ---------------------------------------------------------------------------
# (52) Live finalize must NOT dead-wait TAIL_TERMINAL_TIMEOUT per aborted job:
# a job already settled by the abort path is skipped before the terminal wait.
# ---------------------------------------------------------------------------
subtest live_finalize_skips_settled_aborted_job => sub {
    my ($driver, $events) = new_driver(
        live  => 1,
        tasks => [{job_id => 'JOB-K', file => 't/k.t', rel_file => 't/k.t', is_try => 1}],
    );

    my $mon = Test2::Harness2::Runner::Monitor->new;
    # A launched (collector 'starting'), then aborted job with NO events file.
    $mon->feed({facet_data => {harness_collector => {uuid => 'UUID-K', name => 't/k.t', run_uuid => 'RUN-1', try => 1}, harness_state_transition => {state => 'starting'}}});
    $mon->feed({facet_data => {harness_runner_job => {job_id => 'JOB-K', file => 't/k.t', state => 'aborted'}}});

    my $start = time;
    $driver->finalize($mon);
    my $elapsed = time - $start;

    ok($elapsed < 1, "live finalize returned promptly (${\ sprintf('%.2f', $elapsed)}s), no per-aborted-job 5s dead-wait");

    my $final = $driver->final_data;
    is($final->{failed}, [['JOB-K', 't/k.t']], "aborted job still rolled up as failed");
    is($final->{pass}, 0, "run rollup is a failure");
};

# ---------------------------------------------------------------------------
# (96) In live tail mode the per-job tailing reader is dropped as soon as its
# terminal is read, so a finished job does not hold an open fd for the whole run.
# ---------------------------------------------------------------------------
subtest live_tail_reader_dropped_on_end => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/y-events.jsonl.zst";

    my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
    $rec->record_event($ev->(assert => {pass => 1, number => 1, details => 'a'}));
    $rec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 1}));
    $rec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
    $rec->finalize;

    my ($driver, $events) = new_driver(
        live  => 1,
        tasks => [{job_id => 'JOB-Y', file => 't/y.t', rel_file => 't/y.t', is_try => 1}],
    );

    my $mon = Test2::Harness2::Runner::Monitor->new;
    $mon->feed({facet_data => {harness_collector => {uuid => 'UUID-Y', name => 't/y.t', events_file => $file, run_uuid => 'RUN-1', try => 1}, harness_state_transition => {state => 'starting'}}});

    $driver->tail($mon);

    my ($end) = grep { $_->facet_data->{harness_job_end} } @$events;
    ok($end, "the job's terminal was read");
    ok(!exists $driver->{tail_readers}{'UUID-Y'}, "the finished job's tailing reader was dropped (no leaked fd)");
};

# JobReader closes and clears its underlying zstd reader on done, so even a
# retained JobReader does not hold the fd.
subtest jobreader_closes_reader_on_done => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/done-events.jsonl.zst";

    my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
    $rec->record_event($ev->(assert => {pass => 1, number => 1, details => 'a'}));
    $rec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 1}));
    $rec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
    $rec->finalize;

    my $reader = Test2::Harness2::JobReader->new(
        job_id => 'JOB-D', job_try => 0, run_id => 'RUN-1', events_file => $file, file => 't/done.t',
    );
    for (1 .. 5) { $reader->poll(1000); last if $reader->done }

    ok($reader->done, "reader reached done");
    ok(!defined $reader->{reader}, "underlying zstd reader closed and cleared on done");
};

# ---------------------------------------------------------------------------
# (17 / TIER-10 #160) With runner output hidden, runner_output_done reports done
# immediately (nothing to drain) so the finalize drain does not dead-wait the
# full DRAIN_RUNNER_OUTPUT_TIMEOUT, and the pipeline finalizes promptly.
# ---------------------------------------------------------------------------
subtest hidden_runner_output_no_stall => sub {
    my $dir = tempdir(CLEANUP => 1);    # a real workdir, so the OLD path would stall

    my ($hidden, undef) = new_driver(show_runner_output => 0, workdir => $dir);
    ok($hidden->runner_output_done, "runner_output_done true immediately when output is hidden");

    my ($shown, undef) = new_driver(show_runner_output => 1, workdir => $dir);
    ok(!$shown->runner_output_done, "with output shown and no reader yet, still reports not-done (unchanged)");

    # End-to-end: a hidden-output producer finalizes fast (< 1s) rather than
    # paying the 5s runner-output dead-wait, and still emits the run rollup so the
    # loop's renderers are driven to finish.
    my ($engine, undef) = new_driver(show_runner_output => 0, workdir => $dir);
    my $producer = App::Yath2::RenderLoop::LiveProducer->new(
        engine     => $engine,
        subscriber => undef,
        monitor    => Test2::Harness2::Runner::Monitor->new,
        done_check => sub { 1 },
    );

    my $start = time;
    my @tail  = $producer->finalize;
    my $elapsed = time - $start;

    ok($elapsed < 1, "hidden-output finalize completed promptly (${\ sprintf('%.2f', $elapsed)}s)");
    ok((grep { $_->facet_data->{harness_final} } @tail), "run rollup (harness_final) still emitted -> renderers get finalized");
};

done_testing;

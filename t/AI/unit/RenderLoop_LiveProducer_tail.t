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

# The LiveProducer drives the Renderer::Driver in LIVE TAIL mode (live => 1): on
# each tick it tails EVERY appearing test collector's events.jsonl.zst and emits
# whatever each file has grown by, so under concurrency the jobs interleave in
# arrival order while each job stays in its own order. This contrasts with the
# default mode (a job's whole file fed at completion). This verifies:
#   * tail mode streams a job's body BEFORE its end (not held to completion)
#   * two concurrent jobs interleave (we see job A and job B body lines
#     intermixed, not one whole job then the other)
#   * within-job order is preserved
#   * every emitted event carries its job identity (job_id) for attribution
#   * the run rollup + tallies still come back through the loop

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

sub build_live_loop ($mon, $tasks) {
    my $sink = StubSink->new;

    my $driver = Test2::Harness2::Renderer::Driver->new(
        settings  => $settings,
        renderers => [],          # collect-only: the loop owns the fan-out
        run_id    => 'RUN-1',
        tasks     => $tasks,
        live      => 1,
    );

    my $producer = App::Yath2::RenderLoop::LiveProducer->new(
        engine     => $driver,
        subscriber => undef,
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

# Announce a starting test collector into the mirror.
sub announce ($mon, $uuid, $name, $file) {
    $mon->feed({facet_data => {
        harness_collector        => {uuid => $uuid, name => $name, events_file => $file, run_uuid => 'RUN-1', try => 0},
        harness_state_transition => {state => 'starting'},
    }});
    return;
}

sub complete ($mon, $uuid) {
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_state_transition => {state => 'completed'}}});
    return;
}

subtest live_tail_interleaves_two_jobs => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $fa  = "$dir/a-events.jsonl.zst";
    my $fb  = "$dir/b-events.jsonl.zst";

    # Two recorders we will write to incrementally from a background process, so
    # the loop sees the files GROW (the tail behavior under test). Each job
    # records 3 asserts then its terminal.
    my $ra = Test2::Collector::Recorder::Zstd->new(file => $fa);
    my $rb = Test2::Collector::Recorder::Zstd->new(file => $fb);

    my $mon = Test2::Harness2::Runner::Monitor->new;
    announce($mon, 'UUID-A', 't/a.t', $fa);
    announce($mon, 'UUID-B', 't/b.t', $fb);

    my ($loop, $sink, $producer) = build_live_loop(
        $mon,
        [
            {job_id => 'JOB-A', file => 't/a.t', rel_file => 't/a.t', job_name => '1'},
            {job_id => 'JOB-B', file => 't/b.t', rel_file => 't/b.t', job_name => '2'},
        ],
    );

    # Background writer interleaves the two files: a1, b1, a2, b2, a3, b3, then
    # each job's terminal. The reader/loop in the parent tails them as they grow.
    my $pid = fork // die "fork: $!";
    unless ($pid) {
        for my $n (1 .. 3) {
            $ra->record_event($ev->(assert => {pass => 1, number => $n, details => "A-assert-$n"}));
            sleep 0.02;
            $rb->record_event($ev->(assert => {pass => 1, number => $n, details => "B-assert-$n"}));
            sleep 0.02;
        }

        $ra->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 1}));
        $ra->record_event($ev->(harness_final_state  => {pass => 1, fail_count => 0, pass_count => 3, assertion_count => 3, exit => 0}));
        $ra->finalize;

        $rb->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 1}));
        $rb->record_event($ev->(harness_final_state  => {pass => 1, fail_count => 0, pass_count => 3, assertion_count => 3, exit => 0}));
        $rb->finalize;
        exit 0;
    }

    # Drive the loop ourselves so we can mark the source done once both files have
    # delivered their terminals (both jobs ended). This mirrors how the command's
    # done_check keys on the subscription, but here we key on both jobs ending.
    my $start = time;
    until ($loop->done) {
        $loop->iterate;

        complete($mon, 'UUID-A');
        complete($mon, 'UUID-B');

        my $a_done = $producer->engine->{by_uuid}{'UUID-A'}{ended};
        my $b_done = $producer->engine->{by_uuid}{'UUID-B'}{ended};
        $mon->{__done} = 1 if $a_done && $b_done;

        last if (time - $start) > 20;    # safeguard
        sleep 0.01;
    }
    $loop->finish;
    waitpid($pid, 0);

    # Extract the ordered sequence of body assertions as (job_id => detail).
    my @body;
    for my $e ($sink->events) {
        my $a = $e->facet_data->{assert} or next;
        my $d = $a->{details} // '';
        next unless $d =~ /^([AB])-assert-(\d+)$/;
        push @body => [$e->job_id, $1, $2];
    }

    # 6 body asserts total (3 per job).
    is(scalar(@body), 6, "all 6 body assertions streamed");

    # Per-job attribution: every A line carries JOB-A's job_id, every B line JOB-B's.
    for my $row (@body) {
        my ($job_id, $tag, $num) = @$row;
        is($job_id, ($tag eq 'A' ? 'JOB-A' : 'JOB-B'), "assert $tag-$num attributed to its job ($job_id)");
    }

    # Within-job order preserved: A's asserts appear 1,2,3 in order; same for B.
    my @a_nums = map { $_->[2] } grep { $_->[1] eq 'A' } @body;
    my @b_nums = map { $_->[2] } grep { $_->[1] eq 'B' } @body;
    is(\@a_nums, [1, 2, 3], "job A asserts rendered in order");
    is(\@b_nums, [1, 2, 3], "job B asserts rendered in order");

    # Interleave: the two jobs' bodies are intermixed, NOT one whole job then the
    # other. With the writer interleaving the files, at least one A line must come
    # after at least one B line AND vice-versa (i.e. not [A A A B B B]).
    my @tags = map { $_->[1] } @body;
    my $first_b = do { my $i = 0; $i++ until $i >= @tags || $tags[$i] eq 'B'; $i };
    my $last_a  = do { my $i = $#tags; $i-- while $i >= 0 && $tags[$i] ne 'A'; $i };
    ok($last_a > $first_b, "jobs interleave: an A line renders after a B line (not whole-job blocks)");

    # Bodies stream live: a job's body asserts render BEFORE its harness_job_end.
    my @seq = map {
        my $f = $_->facet_data;
        $f->{harness_job_end} ? ['end', $_->job_id]
            : ($f->{assert} && ($f->{assert}{details} // '') =~ /^([AB])-assert/) ? ['assert', $_->job_id]
            : ()
    } $sink->events;
    my ($a_end_at) = grep { $seq[$_][0] eq 'end' && $seq[$_][1] eq 'JOB-A' } 0 .. $#seq;
    my ($a_first_assert) = grep { $seq[$_][0] eq 'assert' && $seq[$_][1] eq 'JOB-A' } 0 .. $#seq;
    ok(defined($a_end_at) && defined($a_first_assert) && $a_first_assert < $a_end_at,
        "job A body streamed BEFORE its end (live, not held to completion)");

    # Run rollup + tallies still come back through the loop.
    is($loop->final_data->{pass}, 1, "run rollup PASSED");
    ok(!$loop->final_data->{failed}, "nothing failed");
    is($loop->tests_seen,   2, "two tests launched");
    is($loop->asserts_seen, 6, "six assertions seen via the loop fan-out");
    is($sink->finished,     1, "sink finish() called once");
};

subtest live_tail_finalize_bounded_wait => sub {
    # A job whose 'completed' transition fires before its events file has flushed
    # its terminal: the live finalize bounded-waits for the terminal (a background
    # writer appends it a moment later) and settles the TRUE passing verdict
    # rather than synthesizing a premature fail.
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/pass-events.jsonl.zst";

    my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
    $rec->record_event($ev->(assert => {pass => 1, number => 1, details => 'P-assert-1'}));
    # do NOT finalize yet: leave the file short of its terminal.

    my $mon = Test2::Harness2::Runner::Monitor->new;
    announce($mon, 'UUID-P', 't/p.t', $file);
    complete($mon, 'UUID-P');
    $mon->{__done} = 1;

    ok(!$mon->collector('UUID-P')->{final_state}, "final_state NOT folded yet (completed first)");

    my ($loop, $sink) = build_live_loop($mon, [{job_id => 'JOB-P', file => 't/p.t', rel_file => 't/p.t', job_name => '1'}]);

    my $pid = fork // die "fork: $!";
    unless ($pid) {
        sleep 0.15;
        $rec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 1}));
        $rec->record_event($ev->(harness_final_state  => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
        $rec->finalize;
        exit 0;
    }

    my $start = time;
    $loop->start;
    waitpid($pid, 0);

    ok((time - $start) >= 0.1, "live finalize bounded-waited for the events-file terminal");

    my ($end) = grep { $_->facet_data->{harness_job_end} } $sink->events;
    ok($end, "a harness_job_end was rendered");
    is($end->facet_data->{harness_job_end}{fail}, 0, "PASSING job rendered fail=0 (NOT prematurely FAILED)");
    is($end->job_id, 'JOB-P', "the end event is attributed to its job");

    is($loop->final_data->{pass}, 1, "run rollup PASSED");
    ok(!$loop->final_data->{failed}, "no failed jobs in rollup");
};

done_testing;

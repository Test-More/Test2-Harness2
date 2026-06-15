use Test2::V0;
# HARNESS-DURATION-SHORT

# Unit tests for the Collector process() loop and _abort_stalled_jobs().
#
# Three subtests:
#
#   1. stalled_alive  -- job stalled, runner alive → sleep is called, no abort
#   2. abort_stalled  -- job stalled, runner dead  → abort synthesizes fail events
#   3. normal_done    -- job completes via poll     → normal facets, no abort
#
# Strategy
# --------
# * MockCollector subclass:
#     - runner_exited() delegates to a scalar ref set per-test
#     - process_tasks() returns 0 (we pre-seed TASKS_DONE / TASKS)
# * Pre-seed JOBS, JOBS_DONE, TASKS_DONE, TASKS, PENDING so the
#   queue-reading paths are never exercised.
# * Override &Test2::Harness2::Collector::sleep (the Time::HiRes import in
#   the Collector namespace) with a counter that dies after N calls, so a
#   logic regression that causes infinite sleeping makes the test FAIL fast
#   instead of hanging.
# * FakeJob objects: minimal duck-type for what process() calls on a
#   JobReader (poll / done / job_id / job_try / file).
# * All tests use keep_dirs => 1 so process() never calls remove_tree.

use strict;
use warnings;

use File::Temp      qw/tempdir/;
use Getopt::Yath::Settings;
use Time::HiRes     qw/time/;

use Test2::Harness2::Collector;
use Test2::Harness2::Run;
use Test2::Harness2::Event;
use Test2::Harness2::Util::UUID qw/gen_uuid/;

# ── sleep guard ─────────────────────────────────────────────────────────────
# Override the imported sleep() in the Collector namespace.  Each subtest
# resets $sleep_count and $sleep_limit before calling process().
our $sleep_count = 0;
our $sleep_limit = 5;    # default; subtests that expect no sleep keep it low

{
    no warnings qw(redefine prototype);
    *Test2::Harness2::Collector::sleep = sub {
        $sleep_count++;
        die "SLEEP_GUARD: exceeded $sleep_limit sleeps\n"
            if $sleep_count > $sleep_limit;
    };
}

# ── MockCollector ────────────────────────────────────────────────────────────
# runner_exited() and process_tasks() are seam points.
{
    package MockCollector;
    use parent -norequire, 'Test2::Harness2::Collector';

    our $RUNNER_EXITED_REF;    # scalar ref, set per test

    sub runner_exited { $$RUNNER_EXITED_REF }
    sub process_tasks { 0 }           # never touch the task-queue files
}

# ── FakeJob ───────────────────────────────────────────────────────────────────
# Minimal duck-type for a JobReader.  $poll_results is an arrayref of
# arrayrefs; each inner arrayref is the list returned on that poll() call.
# Once all lists are exhausted poll() returns ().  Setting $done_after_poll
# marks done() true after the specified poll index (1-based).
{
    package FakeJob;

    sub new {
        my ($class, %args) = @_;
        bless {
            id           => $args{job_id},
            try          => $args{job_try} // 0,
            file         => $args{file}    // 't/fake.t',
            _polls       => $args{polls}   // [],  # [ [events...], [events...], ... ]
            _poll_idx    => 0,
            _done        => 0,
            _done_after  => $args{done_after} // 0,  # set done after this many polls
        }, $class;
    }

    sub job_id  { $_[0]->{id} }
    sub job_try { $_[0]->{try} }
    sub file    { $_[0]->{file} }
    sub done    { $_[0]->{_done} }

    sub poll {
        my $self = shift;
        return () if $self->{_done};

        my $idx   = $self->{_poll_idx}++;
        my $batch = $self->{_polls}[$idx] // [];

        if ($self->{_done_after} && $self->{_poll_idx} >= $self->{_done_after}) {
            $self->{_done} = { retry => 0 };
        }

        return @$batch;
    }
}

# ── helpers ───────────────────────────────────────────────────────────────────

my $RUN_ID = 'UNIT-RUN-1';

sub make_settings {
    my $settings = Getopt::Yath::Settings->new;
    $settings->group('collector', 1)->create_option(max_open_jobs   => 1024);
    $settings->group('collector', 1)->create_option(max_poll_events => 1000);
    $settings->group('debug',     1)->create_option(keep_dirs       => 1);
    return $settings;
}

# Build a MockCollector with a fresh tempdir.  The run_dir is created for us.
sub make_collector {
    my (%args) = @_;

    my $tmp = tempdir(CLEANUP => 1);
    mkdir "$tmp/$RUN_ID" or die "mkdir: $!";

    my $run      = Test2::Harness2::Run->new(run_id => $RUN_ID);
    my $settings = $args{settings} // make_settings();

    my @events;
    my $c = MockCollector->new(
        run       => $run,
        workdir   => $tmp,
        run_id    => $RUN_ID,
        settings  => $settings,
        action    => sub { push @events, $_[0] },
        wait_time => 0.001,
    );

    # Pre-seed queue state so neither jobs() nor process_tasks() tries to open
    # any queue file.
    $c->{Test2::Harness2::Collector::JOBS_DONE()}   = 1;
    $c->{Test2::Harness2::Collector::TASKS_DONE()}  = $args{tasks_done}  // 1;
    $c->{Test2::Harness2::Collector::TASKS()}       = $args{tasks}       // {};
    $c->{Test2::Harness2::Collector::PENDING()}     = $args{pending}     // {};
    $c->{Test2::Harness2::Collector::JOBS()}        = $args{jobs}        // {};

    return ($c, \@events);
}

# Build a harness event for use in FakeJob poll results.
sub make_harness_event {
    my (%fd) = @_;
    return Test2::Harness2::Event->new(
        event_id   => gen_uuid(),
        job_id     => $fd{harness_job_exit} ? $fd{harness_job_exit}{job_id} : '0',
        job_try    => $fd{harness_job_exit} ? ($fd{harness_job_exit}{job_try} // 0) : 0,
        run_id     => $RUN_ID,
        stamp      => time(),
        facet_data => \%fd,
    );
}

# ════════════════════════════════════════════════════════════════════════════
# Subtest 1: stalled job, runner ALIVE → sleep is called, NO abort
# ════════════════════════════════════════════════════════════════════════════

subtest stalled_alive => sub {
    # Runner stays alive.  The sleep guard triggers after 3 sleeps and we
    # catch the exception — that proves the loop waited (slept) rather than
    # aborting or spinning hot.  No harness_job_exit{aborted} must be emitted.

    my $runner_exited = 0;    # 0 = runner still alive (not yet exited)
    local $MockCollector::RUNNER_EXITED_REF = \$runner_exited;

    local $main::sleep_count = 0;
    local $main::sleep_limit = 3;

    my $job_id = 'JOB-STALL';
    my $fake   = FakeJob->new(
        job_id  => $job_id,
        job_try => 0,
        # polls is empty — always returns () and done stays false → stalled
    );

    my ($c, $evref) = make_collector(
        jobs    => { "$job_id+0" => $fake },
        tasks   => { $job_id => { job_id => $job_id, file => 't/stall.t' } },
    );

    # Hang guard: if the sleep() call is removed (old busy-spin bug), the loop
    # will spin forever without ever calling our override.  alarm() catches that.
    my $timed_out = 0;
    local $SIG{ALRM} = sub { $timed_out = 1; die "ALARM\n" };
    alarm(3);

    my $ok  = eval { $c->process(); 1 };
    my $err = $@;

    alarm(0);

    if ($timed_out || ($err && $err =~ /ALARM/)) {
        fail("process() hung — sleep was not called for stalled+alive job (busy-spin regression)");
        return;
    }

    # We EXPECT the sleep guard to fire (SLEEP_GUARD exception).
    # If the loop exited cleanly, the abort path would have run — also
    # fine to detect (but would mean runner_exited returned true, which
    # it won't here).
    if ($err && $err =~ /SLEEP_GUARD/) {
        ok(1, "loop slept (sleep guard triggered after $sleep_count sleep calls)");
    }
    elsif ($ok) {
        # Should only happen if the job somehow completed — fail the subtest.
        fail("process() exited without sleeping; stalled job was not waited on");
    }
    else {
        fail("unexpected error: $err");
    }

    ok($sleep_count >= 1, "sleep was called at least once (got $sleep_count)");

    # The job must NOT have been aborted (runner is still alive).
    my @abort_evs = grep {
        defined $_ &&
        $_->can('facet_data') &&
        do { my $fd = $_->facet_data; $fd && $fd->{harness_job_exit} && $fd->{harness_job_exit}{aborted} }
    } @$evref;

    is(scalar @abort_evs, 0, "no harness_job_exit{aborted} emitted while runner is alive");

    # The job must still be present in %JOBS (it was not removed/aborted).
    ok(exists $c->{Test2::Harness2::Collector::JOBS()}{"$job_id+0"},
        "job still in %JOBS — not incorrectly removed");
};

# ════════════════════════════════════════════════════════════════════════════
# Subtest 2: stalled job, runner DEAD → _abort_stalled_jobs fires, fail rollup
# ════════════════════════════════════════════════════════════════════════════

subtest abort_stalled => sub {
    my $exited = 1;
    local $MockCollector::RUNNER_EXITED_REF = \$exited;

    local $main::sleep_count = 0;
    local $main::sleep_limit = 0;   # any sleep is a bug — abort path must NOT sleep

    my $job_id = 'JOB-ABORT';
    my $fake   = FakeJob->new(
        job_id  => $job_id,
        job_try => 0,
        file    => 't/abort.t',
        # no polls → stalled
    );

    my ($c, $evref) = make_collector(
        jobs    => { "$job_id+0" => $fake },
        tasks   => { $job_id => { job_id => $job_id, file => 't/abort.t' } },
    );

    # Hang guard: if _abort_stalled_jobs is broken the loop spins without
    # ever sleeping (so the sleep guard above never fires).  Use alarm() to
    # enforce a 3-second wall-clock limit.
    my $timed_out = 0;
    local $SIG{ALRM} = sub { $timed_out = 1; die "ALARM\n" };
    alarm(3);

    my $ok  = eval { $c->process(); 1 };
    my $err = $@;

    alarm(0);    # cancel alarm

    if ($timed_out || ($err && $err =~ /ALARM/)) {
        fail("process() hung — _abort_stalled_jobs did not clear the stalled job (TIMEOUT)");
        # Bail early: remaining assertions are moot and we already failed.
        return;
    }

    if ($err && $err =~ /SLEEP_GUARD/) {
        fail("process() slept during runner-dead abort path (sleep_count=$sleep_count)");
    }
    elsif (!$ok) {
        fail("process() died unexpectedly: $err");
    }
    else {
        pass("process() exited cleanly (no hang, no unexpected sleep)");
    }

    # There must be exactly ONE synthetic harness_job_exit with aborted=1.
    my @exit_evs = grep {
        defined $_ &&
        $_->can('facet_data') &&
        do { my $fd = $_->facet_data; $fd && $fd->{harness_job_exit} }
    } @$evref;

    is(scalar @exit_evs, 1, "exactly one harness_job_exit event");
    my $exit_fd = $exit_evs[0]->facet_data->{harness_job_exit};
    is($exit_fd->{aborted}, 1, "harness_job_exit has aborted=1");
    is($exit_fd->{exit},   -1, "harness_job_exit has exit=-1");
    is($exit_fd->{code},   -1, "harness_job_exit has code=-1");

    # There must be exactly ONE harness_job_end with fail=1, aborted=1.
    my @end_evs = grep {
        defined $_ &&
        $_->can('facet_data') &&
        do { my $fd = $_->facet_data; $fd && $fd->{harness_job_end} }
    } @$evref;

    is(scalar @end_evs, 1, "exactly one harness_job_end event");
    my $end_fd = $end_evs[0]->facet_data->{harness_job_end};
    is($end_fd->{fail},    1, "harness_job_end has fail=1");
    is($end_fd->{aborted}, 1, "harness_job_end has aborted=1");

    # harness_final must have pass=0 and the aborted job in failed[].
    my @final_evs = grep {
        defined $_ &&
        $_->can('facet_data') &&
        do { my $fd = $_->facet_data; $fd && $fd->{harness_final} }
    } @$evref;

    is(scalar @final_evs, 1, "exactly one harness_final event");
    my $hf = $final_evs[0]->facet_data->{harness_final};
    is($hf->{pass}, 0, "harness_final has pass=0 (run failed)");
    my @failed_ids = map { $_->[0] } @{ $hf->{failed} // [] };
    ok(grep({ $_ eq $job_id } @failed_ids), "aborted job_id appears in harness_final{failed}");

    # %JOBS must be empty — the job was removed.
    is(scalar keys %{ $c->{Test2::Harness2::Collector::JOBS()} }, 0,
        "%JOBS is empty after abort (job removed)");
};

# ════════════════════════════════════════════════════════════════════════════
# Subtest 3: job completes via poll → normal facets, NOT aborted
# ════════════════════════════════════════════════════════════════════════════

subtest normal_done => sub {
    my $exited = 1;
    local $MockCollector::RUNNER_EXITED_REF = \$exited;

    local $main::sleep_count = 0;
    local $main::sleep_limit = 2;   # should not sleep at all — job is done in one poll

    my $job_id = 'JOB-PASS';
    my $stamp  = time();

    # First poll returns a job_exit + job_end (pass); done() becomes true.
    my $exit_event = make_harness_event(
        harness_job_exit => {
            exit    => 0,
            code    => 0,
            signal  => 0,
            dumped  => 0,
            retry   => 0,
            aborted => 0,
            job_id  => $job_id,
            job_try => 0,
            stamp   => $stamp,
            details => 'Test script exited 0',
        },
        harness_job_end => {
            fail    => 0,
            aborted => 0,
            retry   => 0,
            file    => 't/pass.t',
            stamp   => $stamp,
        },
    );

    my $fake = FakeJob->new(
        job_id     => $job_id,
        job_try    => 0,
        file       => 't/pass.t',
        polls      => [ [$exit_event] ],  # one poll batch, then exhausted
        done_after => 1,                  # done after 1st poll call
    );

    my ($c, $evref) = make_collector(
        jobs    => { "$job_id+0" => $fake },
        tasks   => { $job_id => { job_id => $job_id, file => 't/pass.t' } },
    );

    my $ok  = eval { $c->process(); 1 };
    my $err = $@;

    if ($err && $err =~ /SLEEP_GUARD/) {
        fail("process() slept unexpectedly (sleep_count=$sleep_count)");
    }
    elsif (!$ok) {
        fail("process() died: $err");
    }
    else {
        pass("process() exited cleanly");
    }

    # The event from poll() must appear in the action stream.
    my @exit_evs = grep {
        defined $_ &&
        $_->can('facet_data') &&
        do { my $fd = $_->facet_data; $fd && $fd->{harness_job_exit} }
    } @$evref;

    is(scalar @exit_evs, 1, "one harness_job_exit emitted");
    my $exit_fd = $exit_evs[0]->facet_data->{harness_job_exit};
    is($exit_fd->{aborted}, 0, "harness_job_exit does NOT have aborted=1");
    is($exit_fd->{exit},    0, "harness_job_exit has exit=0 (clean exit)");

    my @end_evs = grep {
        defined $_ &&
        $_->can('facet_data') &&
        do { my $fd = $_->facet_data; $fd && $fd->{harness_job_end} }
    } @$evref;

    is(scalar @end_evs, 1, "one harness_job_end emitted");
    my $end_fd = $end_evs[0]->facet_data->{harness_job_end};
    is($end_fd->{fail},    0, "harness_job_end has fail=0");
    is($end_fd->{aborted}, 0, "harness_job_end does NOT have aborted=1");

    # harness_final must show pass=1 (no failures).
    my @final_evs = grep {
        defined $_ &&
        $_->can('facet_data') &&
        do { my $fd = $_->facet_data; $fd && $fd->{harness_final} }
    } @$evref;

    is(scalar @final_evs, 1, "one harness_final event");
    my $hf = $final_evs[0]->facet_data->{harness_final};
    is($hf->{pass}, 1, "harness_final has pass=1");
    is(scalar @{ $hf->{failed} // [] }, 0, "no jobs in harness_final{failed}");

    # %JOBS is empty — job was removed after it completed.
    is(scalar keys %{ $c->{Test2::Harness2::Collector::JOBS()} }, 0,
        "%JOBS is empty after normal completion");
};

done_testing;

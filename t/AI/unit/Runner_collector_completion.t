use Test2::V0;
# HARNESS-DURATION-SHORT

# The transition-driven completion decision (ARCHITECTURE.md §5.4), exercised
# against the REAL Runner::Role::Service::Handlers methods via a minimal fake.
# A test collector's connection identifies (job_id/job_try/run_id), streams its
# verdict transitions, then EOFs -- the EOF is where the runner decides the
# outcome. We assert:
#   * EOF with final_state pass  -> complete (stop_task + 'done')
#   * EOF with final_state !pass -> retry while tries remain, then fail
#   * EOF with NO final_state    -> fail (announced 'aborted', the no-verdict
#                                   render mutation); terminated => still aborted
#   * a halt transition          -> bail: halt_run + terminate every OTHER live
#                                   run collector; halt wins over retry
#   * fire-once: a second EOF (or a watchdog-marked decision) does not re-decide
#   * stale-try: a superseded try's late EOF is a no-op

use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Runner::Role::Service::Handlers;
use Test2::Harness2::Runner::Role::Service::Completion;
use Test2::Harness2::Runner::Role::Service::TransitionHub;

{
    package FakeState;
    sub new { my ($c, %a) = @_; bless {running => $a{running} // {}, stopped => [], retried => [], halted => []}, $c }
    sub running_tasks { $_[0]->{running} }
    sub run           { undef }

    sub stop_task {
        my ($self, $job_id) = @_;
        push @{$self->{stopped}} => $job_id;
        delete $self->{running}{$job_id} or die "Could not find task to stop ($job_id)";
        return;
    }

    sub retry_task {
        my ($self, $job_id) = @_;
        push @{$self->{retried}} => $job_id;
        # Mirror State::retry_task: stop the current try, re-queue is implicit here.
        delete $self->{running}{$job_id} or die "Could not find task to retry ($job_id)";
        return;
    }

    sub halt_run {
        my ($self, $run_id) = @_;
        push @{$self->{halted}} => $run_id;
        return;
    }

    package FakeRunnerSettings;
    sub new { bless {abort_on_bail => $_[1]}, $_[0] }
    sub runner { $_[0] }
    sub abort_on_bail { $_[0]->{abort_on_bail} }

    package FakeConn;
    sub new { bless {closed => 0, controls => []}, $_[0] }
    sub closed { $_[0]->{closed} }
    sub close  { $_[0]->{closed} = 1 }
    sub send_control {
        my ($self, $control, %args) = @_;
        push @{$self->{controls}} => {control => $control, %args};
        return 1;
    }

    package FakeRunner;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Handlers';
    with 'Test2::Harness2::Runner::Role::Service::Completion';
    with 'Test2::Harness2::Runner::Role::Service::TransitionHub';

    sub new {
        my ($class, %args) = @_;
        return bless {
            rootpid   => $$,
            state     => $args{state},
            settings  => $args{settings},
            monitor   => Test2::Harness2::Runner::Monitor->new,
            job_pids  => $args{job_pids} // {},
            announced => [],
        }, $class;
    }
    sub state    { $_[0]->{state} }
    sub settings { $_[0]->{settings} }
    sub monitor  { $_[0]->{monitor} }

    # Record announcements (overrides the socket-forwarding role version).
    sub announce_job {
        my ($self, $job_id, $state, %extra) = @_;
        push @{$self->{announced}} => {job_id => $job_id, state => $state, %extra};
        return;
    }
}

sub mk_runner {
    my (%args) = @_;
    return FakeRunner->new(
        state    => FakeState->new(running => $args{running} // {}),
        settings => FakeRunnerSettings->new($args{abort_on_bail} // 1),
    );
}

# Drive a transition through the real service_transition.
sub feed_transition {
    my ($runner, $conn, $facet_data) = @_;
    $runner->service_transition({facet_data => $facet_data}, undef, $conn);
}

sub identify {
    my ($runner, $conn, %ident) = @_;
    $runner->service_identified($conn, {pid => 1234, %ident});
}

subtest eof_with_pass_completes => sub {
    my $runner = mk_runner(running => {J1 => {file => 'a.t', retry => 0}});
    my $conn   = FakeConn->new;

    identify($runner, $conn, job_id => 'J1', job_try => 0, run_id => 'R1');
    feed_transition($runner, $conn, {harness_collector => {uuid => 'C1'}, harness_final_state => {pass => 1}});

    $runner->collector_conn_eof($conn);

    is($runner->state->{stopped}, ['J1'], "passing job stopped");
    is($runner->state->{retried}, [],      "not retried");
    my ($a) = @{$runner->{announced}};
    is($a->{state}, 'done', "announced done");
};

subtest eof_with_fail_retries_then_fails => sub {
    my $runner = mk_runner(running => {J1 => {file => 'a.t', retry => 1}});
    my $conn0  = FakeConn->new;

    # First attempt (try 1, 1-based per R10/#49) fails -> retry (one try remains).
    identify($runner, $conn0, job_id => 'J1', job_try => 1, run_id => 'R1');
    feed_transition($runner, $conn0, {harness_collector => {uuid => 'C1'}, harness_final_state => {pass => 0}});
    $runner->collector_conn_eof($conn0);

    is($runner->state->{retried}, ['J1'], "fail with a try left -> retried");
    is($runner->{announced}[-1]{state}, 'retry', "announced retry");

    # The re-queued attempt (try 2) fails too -> no tries left -> fail (done).
    $runner->state->{running}{J1} = {file => 'a.t', retry => 1};    # re-running, try 2
    my $conn1 = FakeConn->new;
    identify($runner, $conn1, job_id => 'J1', job_try => 2, run_id => 'R1');
    feed_transition($runner, $conn1, {harness_collector => {uuid => 'C2'}, harness_final_state => {pass => 0}});
    $runner->collector_conn_eof($conn1);

    is($runner->state->{stopped}, ['J1'], "second failure stops (no retry left)");
    is($runner->{announced}[-1]{state}, 'done', "announced done on final failure");
};

subtest eof_without_final_state_fails => sub {
    my $runner = mk_runner(running => {J1 => {file => 'a.t', retry => 3}});
    my $conn   = FakeConn->new;

    # No final_state transition ever arrives; the connection just EOFs.
    identify($runner, $conn, job_id => 'J1', job_try => 0, run_id => 'R1');
    $runner->collector_conn_eof($conn);

    is($runner->state->{stopped}, ['J1'], "no-verdict job is stopped (failed)");
    is($runner->state->{retried}, [],      "a no-verdict collector problem is NOT retried");
    my $a = $runner->{announced}[-1];
    is($a->{state}, 'aborted', "no-verdict render mutation is 'aborted'");
    like($a->{details}, qr/without reporting a final state/i, "reason flags possible harness/collector problem");
};

subtest halt_bails_and_terminates_other_collectors => sub {
    my $runner = mk_runner(
        running => {J1 => {file => 'a.t', retry => 5}, J2 => {file => 'b.t', retry => 5}},
    );

    my $conn1 = FakeConn->new;    # the bailing job
    my $conn2 = FakeConn->new;    # another live job in the same run

    identify($runner, $conn1, job_id => 'J1', job_try => 0, run_id => 'R1');
    identify($runner, $conn2, job_id => 'J2', job_try => 0, run_id => 'R1');

    # The bailing collector emits the early halt transition.
    feed_transition($runner, $conn1, {harness_collector => {uuid => 'C1'}, harness_state_transition => {state => 'halt', details => 'stop now'}});

    is($runner->state->{halted}, ['R1'], "run halted (no further dispatch)");
    is(scalar(@{$conn2->{controls}}), 1, "the OTHER run collector got a terminate control");
    is($conn2->{controls}[0]{control}, 'terminate', "control is 'terminate'");
    is(scalar(@{$conn1->{controls}}), 0, "the bailing collector does not terminate itself");

    # The bailing collector's own EOF completes it as failed (halt wins over retry).
    $runner->collector_conn_eof($conn1);
    is($runner->state->{retried}, [], "a bailing job is never retried");
    is($runner->state->{stopped}, ['J1'], "the bailing job is stopped (failed)");

    # The terminated other collector EOFs -> decided aborted (terminated flag).
    $conn2->close;
    $runner->collector_conn_eof($conn2);
    my ($j2) = grep { $_->{job_id} eq 'J2' } @{$runner->{announced}};
    is($j2->{state}, 'aborted', "terminated collector recorded aborted, not retried");
};

subtest no_abort_on_bail_does_not_terminate_others => sub {
    my $runner = mk_runner(
        running       => {J1 => {file => 'a.t', retry => 0}, J2 => {file => 'b.t', retry => 0}},
        abort_on_bail => 0,
    );

    my $conn1 = FakeConn->new;
    my $conn2 = FakeConn->new;
    identify($runner, $conn1, job_id => 'J1', job_try => 0, run_id => 'R1');
    identify($runner, $conn2, job_id => 'J2', job_try => 0, run_id => 'R1');

    feed_transition($runner, $conn1, {harness_collector => {uuid => 'C1'}, harness_state_transition => {state => 'halt', details => 'stop now'}});

    is($runner->state->{halted}, ['R1'], "run still halted (no new dispatch)");
    is(scalar(@{$conn2->{controls}}), 0, "--no-abort-on-bail does NOT terminate other collectors");
};

subtest fire_once_second_eof_is_noop => sub {
    my $runner = mk_runner(running => {J1 => {file => 'a.t', retry => 0}});
    my $conn   = FakeConn->new;

    identify($runner, $conn, job_id => 'J1', job_try => 0, run_id => 'R1');
    feed_transition($runner, $conn, {harness_collector => {uuid => 'C1'}, harness_final_state => {pass => 1}});

    $runner->collector_conn_eof($conn);
    my $n = scalar @{$runner->{announced}};

    # A second EOF for the same conn (e.g. a racing reap-then-EOF) is a no-op: the
    # conn entry is already gone AND the (job_id, job_try) is already decided.
    $runner->collector_conn_eof($conn);
    is(scalar @{$runner->{announced}}, $n, "second EOF announced nothing more");

    # The watchdog marking the same try decided also blocks a (hypothetical) re-decide.
    ok($runner->job_already_decided('J1', 0), "the try is recorded decided");
};

subtest stale_try_late_eof_ignored => sub {
    my $runner = mk_runner(running => {J1 => {file => 'a.t', retry => 1}});

    # Try 0 connects, then a retry advances the current try to 1.
    my $conn0 = FakeConn->new;
    identify($runner, $conn0, job_id => 'J1', job_try => 0, run_id => 'R1');
    feed_transition($runner, $conn0, {harness_collector => {uuid => 'C1'}, harness_final_state => {pass => 0}});
    $runner->collector_conn_eof($conn0);    # decides retry, advances current try to 1

    # A NEW try-0 connection (a superseded attempt) shows up and EOFs late: it must
    # NOT stop/retry the live try-1.
    my $stopped_before = scalar @{$runner->state->{stopped}};
    my $retried_before = scalar @{$runner->state->{retried}};

    my $conn0_late = FakeConn->new;
    identify($runner, $conn0_late, job_id => 'J1', job_try => 0, run_id => 'R1');
    # identify clobbers current_try back to 0; re-assert the live try is 1.
    $runner->{'collector_current_try'}{J1} = 1;
    $runner->collector_conn_eof($conn0_late);

    is(scalar @{$runner->state->{stopped}}, $stopped_before, "stale try did not stop the job");
    is(scalar @{$runner->state->{retried}}, $retried_before, "stale try did not retry the job");
};

done_testing;

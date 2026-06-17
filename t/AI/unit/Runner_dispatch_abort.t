use Test2::V0;
# HARNESS-DURATION-SHORT

# When the runner dispatches a stage-bound task to a preload stage that is gone,
# the dispatch send is a no-op: chunk 9 routes dispatch over the registered
# service channel (service_send by peer identity), so a stage whose connection has
# dropped has no peer and service_send returns false -- the same "stage gone"
# signal the old connect-out client surfaced. Before the fix the runner still
# announced the job as 'dispatched' and left it tracked as RUNNING forever -- no
# stage would ever run it or report stop_task/retry_task -- so clear_finished_run
# could never finish and the run hung.
#
# dispatch_pending aborts-and-clears a job whose send was a no-op (via the same
# Watchdog machinery used on wind-down) instead of announcing 'dispatched'. This
# drives the real Runner::dispatch_pending against a minimal fake runner whose
# service_send reports a failed dispatch, and asserts:
#   * the job is stopped in the scheduler (slot / resources released, RUNNING--);
#   * it is announced/folded as 'aborted' (failed) with a diagnostic, NOT
#     'dispatched';
#   * a job whose dispatch DID succeed is announced 'dispatched' as before, and
#     the run_task frame is sent to that stage's peer identity.

use Test2::Harness2::Runner;
use Test2::Harness2::Runner::Watchdog;
use Test2::Harness2::Runner::Monitor;

# ---------------------------------------------------------------------------
# A minimal stand-in for the runner exercising the REAL dispatch_pending method.
# It provides only what dispatch_pending touches: the rootpid + stage slots, a
# state object (take_dispatch_tasks / run_item / stop_task / running_tasks), a
# service_send that records each send and returns a per-stage result, a real
# Watchdog, and announce_job wired exactly as the runner does (fold into a real
# Monitor).
# ---------------------------------------------------------------------------
{
    package FakeState;
    sub new { my ($c, %a) = @_; bless {running => $a{running} // {}, dispatch => $a{dispatch} // [], stopped => []}, $c }
    sub run_item          { return {run_id => 'R1'} }
    sub running_tasks     { $_[0]->{running} }
    sub take_dispatch_tasks {
        my ($self, $root_stage) = @_;
        my @out = @{$self->{dispatch}};
        @{$self->{dispatch}} = ();
        return @out;
    }
    sub stop_task {
        my ($self, $job_id) = @_;
        push @{$self->{stopped}} => $job_id;
        delete $self->{running}{$job_id}
            or die "Task is not running, cannot stop it ($job_id)";
        return;
    }

    package FakeRunner;
    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            rootpid   => $$,
            stage     => 'default',
            state     => $args{state},
            monitor   => Test2::Harness2::Runner::Monitor->new,
            send_ok   => $args{send_ok} // {},
            sent      => [],
        }, $class;
        return $self;
    }
    sub state    { $_[0]->{state} }
    sub monitor  { $_[0]->{monitor} }
    sub watchdog { $_[0]->{watchdog} //= Test2::Harness2::Runner::Watchdog->new(runner => $_[0]) }

    # Mirror Role::Service::service_send: write to the named peer, false if there
    # is no live connection to it. Here we record the send and return the
    # per-identity result the test set up.
    sub service_send {
        my ($self, $identity, $message) = @_;
        push @{$self->{sent}} => [$identity, $message];
        return $self->{send_ok}{$identity} ? 1 : 0;
    }

    sub announce_job {
        my ($self, $job_id, $state, %extra) = @_;
        push @{$self->{announced}} => {job_id => $job_id, state => $state, %extra};
        $self->{monitor}->feed({facet_data => {harness_runner_job => {job_id => $job_id, state => $state, %extra}}});
        return;
    }
}

subtest failed_dispatch_aborts_and_clears_running => sub {
    my $task = {job_id => 'JOB-A', stage => 'ALPHA', file => 't/a.t', run_id => 'R1'};

    my $state = FakeState->new(
        running  => {'JOB-A' => $task},
        dispatch => [$task],
    );

    # No live channel to preload-ALPHA: service_send reports a failed dispatch.
    my $runner = FakeRunner->new(state => $state, send_ok => {});

    # Run the REAL method against the fake runner.
    Test2::Harness2::Runner::dispatch_pending($runner);

    # The stuck-running job was stopped in the scheduler (slot / resources freed).
    is($state->{stopped}, ['JOB-A'], "the undispatchable job was stopped (RUNNING cleared)");

    # It was announced as aborted (failed), NOT dispatched.
    my @states = map { $_->{state} } @{$runner->{announced}};
    is(\@states, ['aborted'], "announced 'aborted', not 'dispatched'");

    my $j = $runner->monitor->job('JOB-A');
    is($j->{state}, 'aborted', "monitor folded it as aborted");
    is($j->{file},  't/a.t',   "carries the file");
    like($j->{details}, qr/Stage 'ALPHA' is gone/, "carries a useful diagnostic");

    is([$runner->monitor->new_aborted_jobs], ['JOB-A'], "surfaced on new_aborted_jobs");
};

subtest successful_dispatch_announces_dispatched => sub {
    my $task = {job_id => 'JOB-B', stage => 'BETA', file => 't/b.t', run_id => 'R1'};

    my $state = FakeState->new(
        running  => {'JOB-B' => $task},
        dispatch => [$task],
    );

    # A live channel to preload-BETA: service_send reports success.
    my $runner = FakeRunner->new(state => $state, send_ok => {'preload-BETA' => 1});

    Test2::Harness2::Runner::dispatch_pending($runner);

    is($state->{stopped}, [], "a healthy dispatch is NOT aborted");
    is(
        $runner->{sent},
        [['preload-BETA', {request => 'run_task', task => $task, run => {run_id => 'R1'}}]],
        "the run_task frame was sent down the stage's peer channel",
    );

    my @states = map { $_->{state} } @{$runner->{announced}};
    is(\@states, ['dispatched'], "announced 'dispatched'");
};

done_testing;

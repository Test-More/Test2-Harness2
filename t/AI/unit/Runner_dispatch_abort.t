use Test2::V0;
# HARNESS-DURATION-SHORT

# When the runner dispatches a stage-bound task to a preload stage that is gone,
# the dispatch send is a no-op: chunk 9 routes dispatch over the registered
# service channel (service_send by peer identity), so a stage whose connection has
# dropped has no peer and service_send returns false -- the same "stage gone"
# signal the old connect-out client surfaced. Such a job was STARTED (RUNNING, slot
# + resources consumed) but NEVER accepted by a stage (it never received the task,
# never forked the job), so it is owed a run -- not a failure.
#
# bloat TODO-3: dispatch_pending now REQUEUES (not aborts) a job whose send was a no-op:
# State::requeue_task releases the slot / resources and puts it back PENDING (no
# retry consumed) to be re-resolved on a later tick. This drives the real
# Runner::dispatch_pending against a minimal fake runner whose service_send reports
# a failed dispatch, and asserts:
#   * the job is stopped/requeued in the scheduler (slot / resources released);
#   * it is announced/folded as 'requeued' (a non-terminal mutation), NOT 'aborted'
#     and NOT 'dispatched', and is NOT surfaced on new_aborted_jobs;
#   * its job_pids entry is cleared;
#   * a job whose dispatch DID succeed is announced 'dispatched' as before, and the
#     run_task frame is sent to that stage's peer identity.

use Test2::Harness2::Runner;
use Test2::Harness2::Runner::Monitor;

# ---------------------------------------------------------------------------
# A minimal stand-in for the runner exercising the REAL dispatch_pending and
# requeue_task methods. It provides only what they touch: the rootpid + stage
# slots, a state object (take_dispatch_tasks / run_item / requeue_task), a
# service_send that records each send and returns a per-stage result, a job_pids
# map, and announce_job wired exactly as the runner does (fold into a real Monitor).
# ---------------------------------------------------------------------------
{
    package FakeState;
    sub new { my ($c, %a) = @_; bless {running => $a{running} // {}, dispatch => $a{dispatch} // [], requeued => []}, $c }
    sub run_item          { return {run_id => 'R1'} }
    sub running_tasks     { $_[0]->{running} }
    sub take_dispatch_tasks {
        my ($self) = @_;
        my @out = @{$self->{dispatch}};
        @{$self->{dispatch}} = ();
        return @out;
    }
    sub requeue_task {
        my ($self, $job_id) = @_;
        push @{$self->{requeued}} => $job_id;
        delete $self->{running}{$job_id}
            or die "Task is not running, cannot requeue it ($job_id)";
        return;
    }

    # The no-preload dispatch arm forks locally and needs the run object.
    sub run { return {run_id => 'R1'} }

    package FakeRunner;

    # Exercise the REAL Runner::requeue_task (the Handlers role method) as a
    # function against this fake, exactly the way dispatch_pending calls it.
    sub requeue_task {
        my ($self, $task) = @_;
        return Test2::Harness2::Runner::Role::Service::Handlers::requeue_task($self, $task);
    }

    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            rootpid     => $$,
            stage       => 'default',
            state       => $args{state},
            monitor     => Test2::Harness2::Runner::Monitor->new,
            send_ok     => $args{send_ok} // {},
            sent        => [],
            launched    => [],
            has_preload => $args{has_preload} // 1,
            job_pids    => $args{job_pids} // {},
        }, $class;
        return $self;
    }
    sub state    { $_[0]->{state} }
    sub settings { $_[0]->{settings} }
    sub monitor  { $_[0]->{monitor} }

    # The dispatch discriminator: a preload run (default here) sends each task to its
    # stage's channel; a no-preload run (has_preload => 0) forks locally instead.
    sub _preload_root_hosts_stages { $_[0]->{has_preload} // 1 }

    # No-preload local launch: record the call instead of forking a real collector.
    sub _launch_local_job {
        my ($self, $task, $run) = @_;
        push @{$self->{launched}} => $task->{job_id};
        return 4242;
    }

    # Mirror Role::Service::service_send($identity, $command, %args): send to the
    # named peer, false if there is no live connection to it. Record the send and
    # return the per-identity result the test set up.
    sub service_send {
        my ($self, $identity, $command, %args) = @_;
        push @{$self->{sent}} => [$identity, $command, \%args];
        return $self->{send_ok}{$identity} ? 1 : 0;
    }

    # Record every announce for assertions, and fold it into the real Monitor like
    # the real announce_job does (so monitor->job reflects the mutation). We override
    # the role's announce_job here because the role version forwards over sockets.
    sub announce_job {
        my ($self, $job_id, $state, %extra) = @_;
        push @{$self->{announced}} => {job_id => $job_id, state => $state, %extra};
        $self->{monitor}->feed({facet_data => {harness_runner_job => {job_id => $job_id, state => $state, %extra}}});
        return;
    }
}

subtest failed_dispatch_requeues_not_aborts => sub {
    my $task = {job_id => 'JOB-A', stage => 'ALPHA', file => 't/a.t', run_id => 'R1'};

    my $state = FakeState->new(
        running  => {'JOB-A' => $task},
        dispatch => [$task],
    );

    # No live channel to preload-ALPHA: service_send reports a failed dispatch.
    my $runner = FakeRunner->new(state => $state, send_ok => {}, job_pids => {'JOB-A' => 4242});

    # Run the REAL method against the fake runner.
    Test2::Harness2::Runner::dispatch_pending($runner);

    # The undispatched job was requeued in the scheduler (slot / resources freed, no
    # retry consumed).
    is($state->{requeued}, ['JOB-A'], "the undispatchable job was requeued (RUNNING released)");

    # Its job_pids entry was cleared.
    ok(!exists $runner->{job_pids}{'JOB-A'}, "the job_pids entry was cleared on requeue");

    # It was announced as requeued (non-terminal), NOT dispatched and NOT aborted.
    my @states = map { $_->{state} } @{$runner->{announced}};
    is(\@states, ['requeued'], "announced 'requeued', not 'dispatched'/'aborted'");

    my $j = $runner->monitor->job('JOB-A');
    is($j->{state}, 'requeued', "monitor folded it as requeued");
    is($j->{file},  't/a.t',    "carries the file");

    # A requeue is NOT a terminal abort -- it must not appear on the aborted list.
    is([$runner->monitor->new_aborted_jobs], [], "a requeue is NOT surfaced on new_aborted_jobs");
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

    is($state->{requeued}, [], "a healthy dispatch is NOT requeued");
    is(
        $runner->{sent},
        [['preload-BETA', 'run_task', {task => $task, run => {run_id => 'R1'}, want_reply => 0}]],
        "the run_task request was sent down the stage's peer channel (one-way: want_reply => 0)",
    );

    my @states = map { $_->{state} } @{$runner->{announced}};
    is(\@states, ['dispatched'], "announced 'dispatched'");
};

subtest no_preload_run_forks_locally => sub {
    # On a no-preload run (TODO-29) there is no stage to dispatch to: dispatch_pending
    # forks the test's collector in this runner via _launch_local_job instead of
    # service_send, for every task take_dispatch_tasks yields.
    my $task = {job_id => 'JOB-C', stage => 'default', file => 't/c.t', run_id => 'R1'};

    my $state = FakeState->new(running => {'JOB-C' => $task}, dispatch => [$task]);
    my $runner = FakeRunner->new(state => $state, has_preload => 0);

    Test2::Harness2::Runner::dispatch_pending($runner);

    is($runner->{launched}, ['JOB-C'], "the no-preload task was launched locally");
    is($runner->{sent},     [],        "nothing was service_send'd (no stage to dispatch to)");
    is($state->{requeued},  [],        "a local launch is never requeued");
};

done_testing;

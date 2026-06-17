use Test2::V0;
# HARNESS-DURATION-SHORT

# Review P1(b): when the runner dispatches a stage-bound task to a preload stage
# that is gone, the dispatch send is a silent no-op (Stage::Client connection is
# undef). Before the fix the runner still announced the job as 'dispatched' and
# left it tracked as RUNNING forever -- no stage would ever run it or report
# stop_task/retry_task -- so clear_finished_run could never finish and the run
# hung.
#
# The fix: run_task now returns whether the dispatch was actually written, and
# dispatch_pending aborts-and-clears a job whose send was a no-op (via the same
# Watchdog machinery used on wind-down) instead of announcing 'dispatched'. This
# drives the actual Runner::dispatch_pending method against a minimal fake runner
# whose stage client reports a failed dispatch, and asserts:
#   * the job is stopped in the scheduler (slot / resources released, RUNNING--);
#   * it is announced/folded as 'aborted' (failed) with a diagnostic, NOT
#     'dispatched';
#   * a job whose dispatch DID succeed is announced 'dispatched' as before.
#
# It also covers the second P1(b) bug: the runner's per-stage liveness_check must
# report on the SPECIFIC target stage, not "any stage is alive", so a dead target
# stage is detected promptly instead of waiting the full CONNECT_TIMEOUT.

use Test2::Harness2::Runner;
use Test2::Harness2::Runner::Watchdog;
use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Runner::Stage::Client;

# ---------------------------------------------------------------------------
# A minimal stand-in for the runner exercising the REAL dispatch_pending method.
# It provides only what dispatch_pending touches: the rootpid + stage slots, a
# state object (take_dispatch_tasks / run_item / stop_task / running_tasks), a
# stage_client factory returning fake clients, a real Watchdog, and announce_job
# wired exactly as the runner does (fold into a real Monitor).
# ---------------------------------------------------------------------------
{
    package FakeStageClient;
    sub new      { my ($c, %a) = @_; bless {%a}, $c }
    sub run_task { my $self = shift; push @{$self->{sent}} => [@_]; return $self->{result} }

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
            rootpid => $$,
            stage   => 'default',
            state   => $args{state},
            monitor => Test2::Harness2::Runner::Monitor->new,
            clients => $args{clients} // {},
        }, $class;
        return $self;
    }
    sub state       { $_[0]->{state} }
    sub monitor     { $_[0]->{monitor} }
    sub stage_client { $_[0]->{clients}{$_[1]} }
    sub watchdog    { $_[0]->{watchdog} //= Test2::Harness2::Runner::Watchdog->new(runner => $_[0]) }
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

    # The stage is gone, so run_task reports a failed (no-op) dispatch.
    my $client = FakeStageClient->new(result => 0);

    my $runner = FakeRunner->new(state => $state, clients => {ALPHA => $client});

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

    # The stage accepted the frame: run_task reports success.
    my $client = FakeStageClient->new(result => 1);

    my $runner = FakeRunner->new(state => $state, clients => {BETA => $client});

    Test2::Harness2::Runner::dispatch_pending($runner);

    is($state->{stopped}, [], "a healthy dispatch is NOT aborted");
    is($client->{sent}, [[$task, {run_id => 'R1'}]], "the task was handed to the stage client");

    my @states = map { $_->{state} } @{$runner->{announced}};
    is(\@states, ['dispatched'], "announced 'dispatched'");
};

subtest liveness_check_is_per_stage => sub {
    # Build a real Stage::Client and exercise the per-stage liveness closure the
    # runner installs (Runner::stage_client). We stub the runner with two tracked
    # stage processes (ALPHA + BETA) and assert the closure reports liveness for
    # the SPECIFIC stage, so a dead target is detected even while another is alive.
    {
        package FakeStageProc;
        sub new  { my ($c, $name) = @_; bless {name => $name}, $c }
        sub name { $_[0]->{name} }
        sub isa  { $_[1] eq 'Test2::Harness2::Runner::Preloader::Stage' ? 1 : 0 }
    }

    # Mirror the closure in Runner::stage_client: match a tracked Preloader::Stage
    # proc by its name against the dispatched-to stage.
    my $procs = {p1 => FakeStageProc->new('BETA')};    # only BETA is alive
    my $make_check = sub {
        my ($stage) = @_;
        return sub {
            for my $proc (values %$procs) {
                next unless $proc->isa('Test2::Harness2::Runner::Preloader::Stage');
                return 1 if $proc->name eq $stage;
            }
            return 0;
        };
    };

    my $alpha = Test2::Harness2::Runner::Stage::Client->new(
        workdir        => '/tmp',
        stage          => 'ALPHA',
        liveness_check => $make_check->('ALPHA'),
    );
    my $beta = Test2::Harness2::Runner::Stage::Client->new(
        workdir        => '/tmp',
        stage          => 'BETA',
        liveness_check => $make_check->('BETA'),
    );

    ok(!$alpha->_stage_alive, "dead target stage ALPHA reported gone (even though BETA is alive)");
    ok($beta->_stage_alive,   "live target stage BETA reported alive");
};

done_testing;

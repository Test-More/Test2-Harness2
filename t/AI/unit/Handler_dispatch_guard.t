use Test2::V0;
use v5.38;
# HARNESS-DURATION-SHORT

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

use Test2::Collector::Util::Socket qw/connect_unix/;
use Test2::Harness2::Role::Service::Connection();
use Test2::Harness2::Runner::State();

# #110: an unguarded request-handler dispatch let ONE malformed, duplicate, or
# misdirected request frame die out of the service loop -- on a persistent runner that
# outer unwind tears down every stage and aborts every in-flight run from every
# terminal. The fix guards the dispatch in three layers:
#   1. Role::Service::_handle_events wraps handle_request in the house eval; a handler
#      die becomes an {ok=>0, error=>...} reply, the daemon survives.
#   2. request_handler_queue_run/queue_task/run_task shape-validate the frame (run/task
#      hashref present; job_id/run_id present; run_task not misdirected to the hub) and
#      reject a duplicate queue_task, all as per-request errors.
#   3. Runner::State::queue_task drops a duplicate as a survivable no-op (the funnel
#      backstop the dispatch eval cannot see -- the buffered flush_submit_buffer replay).

# --- Layer 1: a dying handler no longer kills the daemon (over the real socket) -------
{
    package My::Svc;
    use v5.38;
    use Object::HashBase qw/<workdir <name <seen/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init ($self) { $self->{+SEEN} = []; return }
    sub service_tick ($self) { return }

    # A handler that dies mid-dispatch -- stands in for any malformed frame that makes a
    # real handler (or the State it drives) throw.
    sub request_handler_boom ($self, $payload, $conn) { die "boom-in-handler\n" }

    # Ordinary work that must keep succeeding AFTER a bad frame.
    sub request_handler_echo ($self, $payload, $conn) {
        push @{$self->{+SEEN}} => $payload->{msg};
        return {ok => 1, msg => $payload->{msg}};
    }
}

subtest dying_handler_is_caught_daemon_survives => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $svc = My::Svc->new(workdir => $dir, name => 'runner');
    $svc->start_service;

    my $cfh = connect_unix($svc->service_socket_path);
    $cfh->blocking(0);
    my $client = Test2::Harness2::Role::Service::Connection->new(fh => $cfh, outbound => 1, my_identity => 'client');

    my $request = sub ($command, %args) {
        my $id = $client->send_request($command, %args);
        for (1 .. 200) {
            $svc->service_io;
            for my $ev ($client->drain) {
                return $ev->{payload} if $ev->{kind} eq 'response' && $ev->{request_id} eq $id;
            }
            sleep 0.01;
        }
        return undef;
    };

    my $lived = 0;
    my $resp;
    ok(lives { $resp = $request->('boom'); $lived = 1 }, "service_io does not die on a bad frame") or diag($@);
    ok($lived, "the service loop survived the bad frame");
    is($resp->{ok}, 0, "the bad frame got an error reply, not a dropped connection");
    like($resp->{error}, qr/boom-in-handler/, "the reply carries the handler error");
    ok(!$svc->service_stopped, "the daemon was NOT stopped by the bad frame");

    # Other in-flight work is unaffected: a following good request still round-trips.
    my $ok = $request->('echo', msg => 'still-here');
    is($ok->{ok},  1,            "a later request still succeeds");
    is($ok->{msg}, 'still-here', "and round-trips its payload");
    is($svc->seen, ['still-here'], "the good handler ran");

    $svc->close_service;
};

# --- Layer 2: request handlers shape-validate + reject duplicate/misdirected ----------
{
    package My::StateHub;    # the runner's canonical state hub: NO enqueue_task
    use v5.38;
    use Object::HashBase qw/<queued/;
    sub task_queued ($self, $job_id) { return $self->{+QUEUED}->{$job_id} ? 1 : 0 }
}
{
    package My::StageState;    # a stage delegate: HAS enqueue_task
    use v5.38;
    use Object::HashBase qw/<enqueued/;
    sub task_queued ($self, $job_id) { return 0 }
    sub enqueue_task ($self, $task, $run) { push @{$self->{+ENQUEUED}} => [$task, $run]; return }
}
{
    package My::Runner;
    use v5.38;
    use Object::HashBase qw/<rootpid <state <settings <submitted/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Handlers';
    sub init ($self) { $self->{+SUBMITTED} //= []; return }
    sub submit_action ($self, $method, @args) { push @{$self->{+SUBMITTED}} => [$method, @args]; return }
}

my $mk_runner = sub (%over) {
    return My::Runner->new(rootpid => $$, state => My::StateHub->new(queued => {}), %over);
};

subtest queue_run_shape => sub {
    my $runner = $mk_runner->();

    my $bad = $runner->request_handler_queue_run({}, undef);
    is($bad->{ok}, 0, "run-less queue_run rejected");
    like($bad->{error}, qr/missing its 'run'/, "error names the missing run");
    is($runner->submitted, [], "a malformed queue_run never reached submit_action/State");

    my $bad2 = $runner->request_handler_queue_run({run => [1, 2]}, undef);
    is($bad2->{ok}, 0, "non-hashref run rejected too");

    my $ok = $runner->request_handler_queue_run({run => {run_id => 'R1'}}, undef);
    is($ok, undef, "a well-formed queue_run is a one-way request (returns undef)");
    is($runner->submitted, [['queue_run', {run_id => 'R1'}]], "the valid run was submitted");
};

subtest queue_task_shape_and_duplicate => sub {
    my $runner = $mk_runner->();

    my $no_task = $runner->request_handler_queue_task({});
    is($no_task->{ok}, 0, "task-less queue_task rejected");
    like($no_task->{error}, qr/missing its 'task'/, "error names the missing task");

    my $no_job = $runner->request_handler_queue_task({task => {run_id => 'R1'}});
    is($no_job->{ok}, 0, "task without job_id rejected");
    like($no_job->{error}, qr/job_id/, "error names job_id");

    my $no_run = $runner->request_handler_queue_task({task => {job_id => 'J1'}});
    is($no_run->{ok}, 0, "task without run_id rejected");
    like($no_run->{error}, qr/run_id/, "error names run_id");

    is($runner->submitted, [], "no malformed queue_task reached submit_action/State");

    my $good = $runner->request_handler_queue_task({task => {job_id => 'J1', run_id => 'R1'}});
    is($good, undef, "a well-formed queue_task is one-way (undef)");
    is($runner->submitted, [['queue_task', {job_id => 'J1', run_id => 'R1'}]], "the valid task was submitted");

    # A duplicate: State reports the job already queued -> per-request error, not a die.
    my $dup_runner = My::Runner->new(rootpid => $$, state => My::StateHub->new(queued => {J1 => 1}));
    my $dup = $dup_runner->request_handler_queue_task({task => {job_id => 'J1', run_id => 'R1'}});
    is($dup->{ok}, 0, "duplicate queue_task rejected");
    like($dup->{error}, qr/duplicate/, "error names the duplicate");
    is($dup_runner->submitted, [], "the duplicate never re-reached submit_action");
};

subtest run_task_misdirection => sub {
    # Misdirected to the runner's state hub (no enqueue_task): rejected, not a die.
    my $hub = My::Runner->new(rootpid => $$, state => My::StateHub->new(queued => {}));
    my $mis = $hub->request_handler_run_task({task => {job_id => 'J1'}, run => {run_id => 'R1'}});
    is($mis->{ok}, 0, "run_task misdirected to the hub is rejected");
    like($mis->{error}, qr/misdirected/, "error names the misdirection");

    my $no_task = $hub->request_handler_run_task({run => {run_id => 'R1'}});
    is($no_task->{ok}, 0, "run_task without a task hashref rejected");
    my $no_run = $hub->request_handler_run_task({task => {job_id => 'J1'}});
    is($no_run->{ok}, 0, "run_task without a run hashref rejected");

    # A stage delegate DOES enqueue it (the legitimate path is unbroken).
    my $stage_state = My::StageState->new(enqueued => []);
    my $stage = My::Runner->new(rootpid => $$, state => $stage_state);
    my $ok = $stage->request_handler_run_task({task => {job_id => 'J1'}, run => {run_id => 'R1'}});
    is($ok, undef, "a well-formed run_task on a stage is one-way (undef)");
    is($stage_state->enqueued, [[{job_id => 'J1'}, {run_id => 'R1'}]], "the stage enqueued the task+run");
};

# --- Layer 3: queue_task's duplicate is a survivable no-op (the funnel backstop) -----
{
    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init ($self) { $self->{resources} = []; $self->{running} = 0; return }
}

subtest state_duplicate_is_nonfatal => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    my $task = {job_id => 'J1', run_id => 'R1', file => 't/x.t', rel_file => 't/x.t', category => 'general', duration => 'medium', use_preload => 1, is_try => 1};
    $state->queue_task($task);
    ok($state->task_queued('J1'), "task_queued reports the queued job");
    ok(!$state->task_queued('nope'), "task_queued is false for an unknown job");

    # A sibling run's task, to prove a duplicate never reaps it.
    my $sib = {%$task, job_id => 'J2', run_id => 'R2'};
    $state->queue_task($sib);

    my $lived = 0;
    my $warnings = warnings { $lived = lives { $state->queue_task({%$task}) } };
    ok($lived, "a duplicate queue_task never dies") or diag($@);
    is(@$warnings, 1, "exactly one warning for the duplicate");
    like($warnings->[0], qr/already queued/, "the warning names the duplicate");

    ok($state->task_queued('J1'), "the original J1 is still queued");
    ok($state->task_queued('J2'), "the sibling run's task is wholly unaffected");
};

done_testing;

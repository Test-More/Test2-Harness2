use Test2::V0;
# HARNESS-DURATION-SHORT

use Test2::Harness2::Runner::State;

# Ticket #12 / ARCHITECTURE.md §4.2: the raw queued run item lives ON the Run object
# (no parallel run_items hash), and the run is retained/purged per the queuing
# client. These tests exercise the State-level pieces (raw_item folding, run_status
# classification, finished-run retention, purge, and run-scoped abort) plus the
# runner-level owner-drop sweep (abort / detach / purge).

# Bypass the heavy init (settings/resources): we drive scheduling state directly. We
# still need a workdir because _queue_run builds a real Runner::Run, which requires it.
{
    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init {}
}

sub new_state { FakeState->new(workdir => '/tmp/fake-workdir', @_) }

subtest raw_item_folded_onto_run => sub {
    my $state = new_state();

    $state->queue_run({run_id => 'R1', extra => 'payload'});
    $state->start_run('R1');

    my $item = $state->run_item;
    ref_ok($item, 'HASH', "run_item returns the raw queued hash");
    is($item->{run_id}, 'R1',      "raw item carries run_id");
    is($item->{extra},  'payload', "raw item carries the rest of the queued payload verbatim");

    is($state->run->raw_item, $item, "the item is the Run object's raw_item (one structure)");

    ok(!$state->can('run_items'), "the leaking run_items accessor is gone");
};

subtest run_status_classification => sub {
    my $state = new_state();

    is($state->run_status('nope'), undef, "an unknown run is undef");

    $state->queue_run({run_id => 'R1'});
    is($state->run_status('R1'), 'running', "a pending (queued) run classifies as running");

    $state->start_run('R1');
    is($state->run_status('R1'), 'running', "the active run classifies as running");
};

subtest finished_run_retained_then_purged => sub {
    my $state = new_state();

    $state->queue_run({run_id => 'R1'});
    $state->start_run('R1');

    # No tasks ever ran; stop the run and clear it. clear_finished_run should retain
    # the finished Run object (queryable by its owner) rather than discard it.
    $state->stop_run('R1');
    ok($state->clear_finished_run, "clear_finished_run retired the active run");

    is($state->run, undef, "no active run after clear");
    is($state->run_status('R1'), 'finished', "the finished run is retained and classifies as finished");
    is($state->retained_runs->{'R1'}->run_id, 'R1', "the retained Run is the canonical Run object");

    ok($state->purge_run('R1'), "purge_run removes the retained run");
    is($state->run_status('R1'), undef, "after purge the run is unknown");
    ok(!$state->retained_runs->{'R1'}, "retained entry is gone");
};

subtest abort_run_halts_and_stops => sub {
    my $state = new_state();

    $state->queue_run({run_id => 'R1'});
    $state->start_run('R1');

    # A pending task for the run; abort_run must halt the run (dropping pending tasks)
    # and mark it stopped so the loop advances off it.
    $state->queue_task({
        job_id   => 'J1', run_id => 'R1',
        category => 'general', duration => 'short',
        stage    => 'default', use_preload => 0,
    });
    ok($state->task_lookup->{'J1'}, "task queued");

    $state->abort_run('R1');

    ok($state->halted_runs->{'R1'}, "the run is halted (no new tasks accepted)");
    ok($state->stopped_runs->{'R1'}, "the run is stopped (loop will advance off it)");

    # Ticket #35: halting the run must also drop its TASK_LOOKUP entries so a stale
    # task can no longer block a same-job_id resubmission and so a persistent runner
    # does not retain the task hashes forever.
    ok(!$state->task_lookup->{'J1'}, "the halted run's task is gone from task_lookup");

    # A halted run drops further task submissions on the floor.
    $state->queue_task({
        job_id   => 'J2', run_id => 'R1',
        category => 'general', duration => 'short',
        stage    => 'default', use_preload => 0,
    });
    ok(!$state->task_lookup->{'J2'}, "a halted run rejects further task submissions");
};

# Ticket #35: purge_run (owner-drop sweep) must also clear the run's TASK_LOOKUP
# entries, not just the pending buckets and bookkeeping.
subtest purge_run_clears_task_lookup => sub {
    my $state = new_state();

    $state->queue_run({run_id => 'R1'});
    $state->start_run('R1');

    $state->queue_task({
        job_id   => 'J1', run_id => 'R1',
        category => 'general', duration => 'short',
        stage    => 'default', use_preload => 0,
    });
    ok($state->task_lookup->{'J1'}, "task queued");

    $state->stop_run('R1');
    $state->clear_finished_run;
    $state->purge_run('R1');

    ok(!$state->task_lookup->{'J1'}, "the purged run's task is gone from task_lookup");
};

# --- Runner-level owner-drop sweep -------------------------------------------------
#
# A tiny harness composes the Handlers role with stub state + watchdog so we can drive
# service_conn_closed / handle_owner_drop without standing up a real runner + sockets.

{
    package FakeWatchdog;
    sub new { bless {aborted => []}, shift }
    sub abort_remaining {
        my ($self, $reason, %p) = @_;
        push @{$self->{aborted}}, {reason => $reason, run_id => $p{run_id}};
        return;
    }
    sub aborted { $_[0]->{aborted} }
}

{
    package FakeRunState;
    sub new { bless {status => {}, purged => [], aborted => []}, shift }
    sub set_status { $_[0]->{status}{$_[1]} = $_[2] }
    sub run_status { $_[0]->{status}{$_[1]} }
    sub purge_run  { push @{$_[0]->{purged}},  $_[1]; return 1 }
    sub abort_run  { push @{$_[0]->{aborted}}, $_[1]; return }
    sub purged  { $_[0]->{purged} }
    sub aborted { $_[0]->{aborted} }
}

{
    package FakeRunner;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Handlers';

    sub new {
        my $class = shift;
        return bless {rootpid => $$, state => FakeRunState->new, watchdog => FakeWatchdog->new, @_}, $class;
    }
    sub state    { $_[0]->{state} }
    sub settings { $_[0]->{settings} }
    sub watchdog { $_[0]->{watchdog} }
}

{
    package FakeConn;
    sub new      { bless {pid => $_[1]}, $_[0] }
    sub peer_pid { $_[0]->{pid} }
}

subtest owner_drop_running_aborts_by_default => sub {
    my $runner = FakeRunner->new;
    my $conn   = FakeConn->new(4242);

    $runner->{state}->set_status('R1', 'running');
    $runner->{run_owners} = {R1 => {conn => $conn, peer_pid => 4242, abort_on_disconnect => 1}};

    $runner->service_conn_closed($conn);

    is($runner->{watchdog}->aborted, [{reason => match(qr/disconnected/), run_id => 'R1'}],
        "running + owner drop + flag true -> watchdog abort_remaining scoped to the run");
    is($runner->{state}->aborted, ['R1'], "abort_run called for the run");
    ok(!$runner->{run_owners}->{R1}, "owner record dropped so the run is not swept twice");
};

subtest owner_drop_running_detaches_when_flag_false => sub {
    my $runner = FakeRunner->new;
    my $conn   = FakeConn->new(4243);

    $runner->{state}->set_status('R1', 'running');
    $runner->{run_owners} = {R1 => {conn => $conn, peer_pid => 4243, abort_on_disconnect => 0}};

    $runner->service_conn_closed($conn);

    is($runner->{watchdog}->aborted, [], "detach: no jobs aborted");
    is($runner->{state}->aborted,    [], "detach: run not aborted (keeps running)");
    ok(!$runner->{run_owners}->{R1}, "owner record dropped (purge-on-completion path)");
};

subtest owner_drop_finished_purges => sub {
    my $runner = FakeRunner->new;
    my $conn   = FakeConn->new(4244);

    $runner->{state}->set_status('R1', 'finished');
    $runner->{run_owners} = {R1 => {conn => $conn, peer_pid => 4244, abort_on_disconnect => 1}};

    $runner->service_conn_closed($conn);

    is($runner->{state}->purged,  ['R1'], "finished + owner drop -> purge_run");
    is($runner->{watchdog}->aborted, [], "finished run is not aborted");
    ok(!$runner->{run_owners}->{R1}, "owner record dropped");
};

subtest owner_drop_only_sweeps_that_conn => sub {
    my $runner = FakeRunner->new;
    my $mine   = FakeConn->new(1);
    my $other  = FakeConn->new(2);

    $runner->{state}->set_status('R1', 'running');
    $runner->{state}->set_status('R2', 'running');
    $runner->{run_owners} = {
        R1 => {conn => $mine,  peer_pid => 1, abort_on_disconnect => 1},
        R2 => {conn => $other, peer_pid => 2, abort_on_disconnect => 1},
    };

    $runner->service_conn_closed($mine);

    is($runner->{state}->aborted, ['R1'], "only the closing connection's run is aborted");
    ok($runner->{run_owners}->{R2}, "another connection's run is untouched");
};

done_testing;

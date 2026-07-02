use Test2::V0;
# HARNESS-DURATION-SHORT

# #135 finding 3: the runner-side monitor + per-job ledgers never pruned, so a
# long-lived persistent runner's RSS climbed forever. announce_run now prunes all
# O(tests) hub-monitor state and DEFERS a live-connection-safe sweep of the run's
# per-job ledgers (decided_jobs / collector_current_try / job_passed), retaining only a
# bounded FIFO ring of O(1)-per-run end markers for late/reconnecting subscribers.

use Test2::Harness2::Runner::Role::Service::Handlers;
use Test2::Harness2::Runner::Role::Service::TransitionHub;
use Test2::Harness2::Util qw/mono_time/;

{
    package FakeState;
    sub new { bless {running => $_[1] // {}}, $_[0] }
    sub running_tasks { $_[0]->{running} }
    sub run           { undef }
    sub purge_run     { return }

    package FakeConn;
    sub new    { bless {closed => 0}, $_[0] }
    sub closed { $_[0]->{closed} }
    sub close  { $_[0]->{closed} = 1 }

    package FakeHubRunner;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Handlers';
    with 'Test2::Harness2::Runner::Role::Service::TransitionHub';

    # Small ring so overflow eviction is cheap to exercise (overrides the role's 100).
    sub _run_marker_retention { 3 }

    sub new {
        my ($class, %args) = @_;
        return bless {
            rootpid       => $$,
            state         => FakeState->new,
            announced_runs => {},
            run_owners    => {},
            forwarded     => [],
        }, $class;
    }
    sub state    { $_[0]->{state} }
    sub settings { undef }
    sub forward_frame { push @{$_[0]->{forwarded}} => $_[1]; return }
}

# Feed one run's worth of monitor state + per-job ledgers into the runner.
sub seed_run {
    my ($runner, $rid, @job_ns) = @_;
    my $mon = $runner->monitor;
    for my $n (@job_ns) {
        my $uuid = "$rid-C$n";
        my $jid  = "$rid-J$n";
        $mon->feed({facet_data => {harness_state_transition => {state => 'starting', stamp => 1},
                                   harness_collector => {uuid => $uuid, name => 't/$n.t', try => 1, run_uuid => $rid}}});
        $mon->feed({facet_data => {harness_runner_job => {job_id => $jid, state => 'done', run_id => $rid}}});
        $runner->{'decided_jobs'}{$jid}{1}       = 1;
        $runner->{'job_passed'}{$jid}            = $rid;
        $runner->{'collector_current_try'}{$jid} = 1;
    }
    $mon->feed({facet_data => {harness_run_health => {run_id => $rid, reason => 'x'}}});
    $runner->{'run_owners'}{$rid} = 1;    # skip the §4.2 owner purge so this is self-contained
}

subtest prune_and_deferred_ledger_sweep => sub {
    my $runner = FakeHubRunner->new;

    seed_run($runner, 'RUN-A', 1, 2);
    seed_run($runner, 'RUN-B', 1);

    $runner->announce_run('RUN-A');

    # Monitor collectors/jobs/health for RUN-A pruned immediately; RUN-B untouched.
    ok(!$runner->monitor->collector('RUN-A-C1'), "RUN-A collectors pruned from the monitor at announce");
    ok($runner->monitor->collector('RUN-B-C1'),  "RUN-B collectors untouched");
    ok(!$runner->monitor->job('RUN-A-J1'),       "RUN-A jobs pruned from the monitor");
    is([map { $_->{run_id} } @{$runner->monitor->run_health}], ['RUN-B'], "only RUN-A run_health pruned");
    ok($runner->monitor->run_done('RUN-A'), "the RUN-A end marker is retained for late subscribers");

    # The per-job ledgers are NOT swept yet (grace has not elapsed).
    ok($runner->{'decided_jobs'}{'RUN-A-J1'}, "decided_jobs held under the sweep grace");
    ok($runner->{'job_passed'}{'RUN-A-J1'},   "job_passed held under the sweep grace");

    # Age the queued sweep past the grace and flush.
    $_->{since} = mono_time - 1000 for @{$runner->{'ledger_sweep'}};
    $runner->_flush_run_ledger_sweeps;

    ok(!$runner->{'decided_jobs'}{'RUN-A-J1'},          "decided_jobs swept after grace");
    ok(!$runner->{'decided_jobs'}{'RUN-A-J2'},          "decided_jobs swept for every job in the run");
    ok(!$runner->{'collector_current_try'}{'RUN-A-J1'}, "collector_current_try swept");
    ok(!$runner->{'job_passed'}{'RUN-A-J1'},            "job_passed swept");
    is($runner->{'ledger_sweep'}, [], "the run's sweep queue entry is dropped once empty");
};

subtest live_connection_defers_the_sweep => sub {
    my $runner = FakeHubRunner->new;
    seed_run($runner, 'RUN-A', 1);

    # An OPEN collector connection still carries the job at retirement (a watchdog-
    # aborted job whose collector has not EOFed): its ledger MUST survive the flush, or
    # its later EOF would re-decide the job.
    my $conn = FakeConn->new;
    $runner->{'collector_conns'}{"$conn"} = {conn => $conn, job_id => 'RUN-A-J1', run_id => 'RUN-A'};

    $runner->announce_run('RUN-A');
    $_->{since} = mono_time - 1000 for @{$runner->{'ledger_sweep'}};
    $runner->_flush_run_ledger_sweeps;

    ok($runner->{'decided_jobs'}{'RUN-A-J1'}, "the ledger survives while the collector connection is open");
    ok(@{$runner->{'ledger_sweep'}},          "the sweep entry stays queued");

    # Once the connection closes, a later flush sweeps it.
    $conn->close;
    $runner->_flush_run_ledger_sweeps;
    ok(!$runner->{'decided_jobs'}{'RUN-A-J1'}, "the ledger is swept once the connection closes");
    is($runner->{'ledger_sweep'}, [], "the queue drains once the deferred job is swept");
};

subtest run_marker_ring_is_bounded => sub {
    my $runner = FakeHubRunner->new;    # ring cap = 3

    for my $i (1 .. 5) {
        seed_run($runner, "R$i", 1);
        $runner->announce_run("R$i");
    }

    is(scalar(@{$runner->{'announced_ring'}}), 3, "the marker ring is bounded to _run_marker_retention");
    is($runner->{'announced_ring'}, ['R3', 'R4', 'R5'], "only the most recent runs' markers are retained");

    ok(!$runner->monitor->run_done('R1'), "an evicted run's end marker is dropped");
    ok(!$runner->monitor->run_done('R2'), "the second-oldest marker is dropped too");
    ok($runner->monitor->run_done('R5'),  "a recent run's end marker survives");

    # The evicted runs' announced_runs keys are cleared too (drop_run_marker leg).
    ok(!$runner->{'announced_runs'}{'R1'}, "evicted run's announced_runs key cleared");
    ok($runner->{'announced_runs'}{'R5'},  "recent run's announced_runs key retained");
};

done_testing;

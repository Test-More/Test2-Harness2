use Test2::V0;
# HARNESS-DURATION-SHORT

use POSIX ();
use Time::HiRes ();

# Phase 2b of the transition-driven completion model (ARCHITECTURE.md §5.4),
# exercised against the REAL Runner::Role::Service::Handlers + Watchdog methods via
# a minimal fake runner. We assert:
#   * abort_run_collectors records an abort intent + terminates every live run
#     collector, and a collector that connects AFTER the intent is terminated on
#     connect (the late-connect path / B4).
#   * the watchdog's run-scoped abort (owner-disconnect, B3) drives the terminate
#     primitive so the test PROCESS is torn down, not just the canonical state, AND
#     marks the job decided so the later collector EOF is a fire-once no-op.
#   * the hard-kill grace fallback fires (kill) for a collector that does not comply
#     within the grace.
#   * the --collector-connect-timeout fails a dispatched job whose collector never
#     connected (it would otherwise never EOF).
#   * a post-pass collector non-zero health exit flags the suite via
#     announce_run_health while the passing test stays decided 'done'.

use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Runner::Role::Service::Handlers;
use Test2::Harness2::Runner::Role::Service::Completion;
use Test2::Harness2::Runner::Role::Service::TransitionHub;
use Test2::Harness2::Runner::Watchdog;

# #134 finding 104: the terminate-grace 'deadline' and the connect-watch 'since'
# are now MONOTONIC (mono_time), so injected values must be on the same clock.
use Test2::Harness2::Util qw/mono_time/;

{
    package FakeState;
    sub new { my ($c, %a) = @_; bless {running => $a{running} // {}, stopped => [], retried => [], halted => [], truncated => 0}, $c }
    sub running_tasks { $_[0]->{running} }
    sub run           { undef }

    sub stop_task {
        my ($self, $job_id) = @_;
        push @{$self->{stopped}} => $job_id;
        delete $self->{running}{$job_id};
        return;
    }

    sub halt_run {
        my ($self, $run_id) = @_;
        push @{$self->{halted}} => $run_id;
        return;
    }

    sub truncate { $_[0]->{truncated}++; return }
    sub purge_run { return }

    package FakeRunnerSettings;
    sub new { bless {abort_on_bail => $_[1] // 1, connect_timeout => $_[2] // 30}, $_[0] }
    sub runner    { $_[0] }
    sub abort_on_bail { $_[0]->{abort_on_bail} }
    sub collector_connect_timeout { $_[0]->{connect_timeout} }
    sub check_group { 1 }

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
        my $self = bless {
            rootpid   => $$,
            state     => $args{state},
            settings  => $args{settings},
            monitor   => Test2::Harness2::Runner::Monitor->new,
            job_pids  => $args{job_pids} // {},
            announced => [],
            health    => [],
            forwarded => [],
        }, $class;
        return $self;
    }
    sub state    { $_[0]->{state} }
    sub settings { $_[0]->{settings} }
    sub monitor  { $_[0]->{monitor} }
    sub rootpid  { $_[0]->{rootpid} }

    sub watchdog { $_[0]->{watchdog} //= Test2::Harness2::Runner::Watchdog->new(runner => $_[0]) }

    sub announce_job {
        my ($self, $job_id, $state, %extra) = @_;
        push @{$self->{announced}} => {job_id => $job_id, state => $state, %extra};
        return;
    }

    # Capture the health announcements (override the socket-forwarding version) but
    # still drive the real fold so a snapshot would carry it.
    sub announce_run_health {
        my ($self, $run_id, $reason) = @_;
        push @{$self->{health}} => {run_id => $run_id, reason => $reason};
        $self->monitor->feed({facet_data => {harness_run_health => {run_id => $run_id, reason => $reason}}});
        return;
    }

    sub forward_frame { push @{$_[0]->{forwarded}} => $_[1]; return }
}

sub mk_runner {
    my (%args) = @_;
    return FakeRunner->new(
        state    => FakeState->new(running => $args{running} // {}),
        settings => FakeRunnerSettings->new($args{abort_on_bail}, $args{connect_timeout}),
    );
}

sub identify {
    my ($runner, $conn, %ident) = @_;
    $runner->service_identified($conn, {pid => $ident{pid} // 1234, %ident});
}

subtest abort_run_collectors_terminates_and_intent => sub {
    my $runner = mk_runner(running => {J1 => {file => 'a.t', run_id => 'R1', is_try => 0}, J2 => {file => 'b.t', run_id => 'R1', is_try => 0}});

    my $conn1 = FakeConn->new;
    identify($runner, $conn1, job_id => 'J1', job_try => 0, run_id => 'R1', pid => 111);

    $runner->abort_run_collectors('R1', 'abort now');
    is($conn1->{controls}[0]{control}, 'terminate', "live collector got a terminate control");
    ok(exists $runner->{aborting_runs}{R1}, "abort intent recorded for the run");

    # A collector that connects AFTER the intent (J2, the B4 late-connect path) is
    # terminated on connect.
    my $conn2 = FakeConn->new;
    identify($runner, $conn2, job_id => 'J2', job_try => 0, run_id => 'R1', pid => 222);
    is($conn2->{controls}[0]{control}, 'terminate', "late-connecting collector terminated on connect");
};

subtest owner_disconnect_abort_kills_process => sub {
    # #135 finding 2: a REAL first attempt carries NO is_try (undef); the collector's
    # wire job_try is 1 (Job.pm sends is_try //= 1). The watchdog marks decided with the
    # raw undef and the EOF checks with the wire 1 -- the `// 1` normalization must
    # collapse both to the SAME key so the abort's later EOF is a fire-once no-op.
    my $runner = mk_runner(running => {J1 => {file => 'a.t', run_id => 'R1'}});

    my $conn1 = FakeConn->new;
    identify($runner, $conn1, job_id => 'J1', job_try => 1, run_id => 'R1', pid => 111);

    # The owner-drop abort path (B3): run-scoped abort_remaining.
    $runner->watchdog->abort_remaining("owner disconnected", run_id => 'R1');

    is($conn1->{controls}[0]{control}, 'terminate', "the running job's collector got a terminate (the PROCESS is torn down)");
    is($runner->{announced}[-1]{state}, 'aborted', "the job is synthesized aborted in canonical state");
    ok($runner->job_already_decided('J1', 1), "the job is marked decided (fire-once, 1-based try)");

    # The terminated collector's later EOF is a fire-once no-op (it does not
    # re-announce/re-decide) -- same key both sides despite undef-vs-1.
    my $before = scalar @{$runner->{announced}};
    $conn1->close;
    $runner->collector_conn_eof($conn1);
    is(scalar @{$runner->{announced}}, $before, "the collector EOF after abort is a no-op (fire-once preserved)");
};

subtest hard_kill_grace_fallback => sub {
    my $runner = mk_runner(running => {J1 => {file => 'a.t', run_id => 'R1', is_try => 0}});

    # A collector whose pid is a HARMLESS live process: this test process itself.
    # The enforcer kill()s the process group; we point it at our own pid so the
    # KILL hits a group that is just us (the test harness tolerates the group kill of
    # its own pid? no -- so use a guaranteed-nonexistent pid and assert the marker).
    my $conn1 = FakeConn->new;
    identify($runner, $conn1, job_id => 'J1', job_try => 0, run_id => 'R1', pid => 2_000_000_000);

    $runner->abort_run_collectors('R1', 'abort now');

    # Force the deadline into the past so the grace has elapsed.
    $runner->{aborting_runs}{R1}{deadline} = mono_time - 1;

    $runner->_enforce_terminate_grace;

    my ($entry) = grep { $_->{job_id} eq 'J1' } values %{$runner->{collector_conns}};
    ok($entry->{hard_killed}, "a non-complying collector past the grace was hard-killed (marker set)");

    # Idempotent: a second pass does not re-kill (the marker guards it).
    ok(lives { $runner->_enforce_terminate_grace }, "a second grace pass is a no-op");
};

subtest connect_timeout_fails_unconnected_job => sub {
    my $runner = mk_runner(
        running         => {J1 => {file => 'a.t', run_id => 'R1'}},
        connect_timeout => 5,
    );

    # The runner marked the job dispatched but no collector ever connects. (The fake
    # overrides announce_job, so set the watch directly -- the real announce_job
    # stamps it; the connect-clear path is covered by the next subtest.)
    $runner->{job_connect_watch}{J1} = {since => mono_time - 10, run_id => 'R1'};

    $runner->_enforce_collector_connect_timeout;

    my ($abort) = grep { $_->{state} eq 'aborted' } @{$runner->{announced}};
    ok($abort, "the never-connecting job was failed (aborted) by the connect timeout");
    like($abort->{details}, qr/did not connect within/i, "reason names the connect timeout");
    # First-attempt task (no is_try): decided under the 1-based normalized key (#135 finding 2).
    ok($runner->job_already_decided('J1', 1), "the timed-out job is marked decided (1-based)");
};

subtest connect_timeout_cleared_on_connect => sub {
    my $runner = mk_runner(
        running         => {J1 => {file => 'a.t', run_id => 'R1', is_try => 0}},
        connect_timeout => 5,
    );

    $runner->announce_job('J1', 'dispatched', run_id => 'R1', file => 'a.t');

    my $conn = FakeConn->new;
    identify($runner, $conn, job_id => 'J1', job_try => 0, run_id => 'R1');
    ok(!exists $runner->{job_connect_watch}{J1}, "the connect watch is cleared once the collector connects");
};

subtest connect_timeout_terminates_late_collector => sub {
    # M1: a collector that connects AFTER the connect-timeout already failed its job
    # (its slot reclaimed) is terminated on connect so its test child does not run on
    # as an orphan. A different job (no intent) or a different try is left alone.
    my $runner = mk_runner(
        running         => {J1 => {file => 'a.t', run_id => 'R1', is_try => 0}},
        connect_timeout => 5,
    );

    $runner->{job_connect_watch}{J1} = {since => mono_time - 10, run_id => 'R1'};
    $runner->_enforce_collector_connect_timeout;
    ok($runner->{terminated_jobs}{J1}, "a per-job termination intent was recorded for the timed-out job");

    # The slow collector for the SAME try connects late -> terminated on connect.
    my $late = FakeConn->new;
    identify($runner, $late, job_id => 'J1', job_try => 0, run_id => 'R1', pid => 555);
    is($late->{controls}[0]{control}, 'terminate', "the late-connecting collector is terminated on connect");
    ok(!exists $runner->{terminated_jobs}{J1}, "the per-job intent is consumed once the late collector connects");

    # A collector for a DIFFERENT job (no intent) connects normally -> NOT terminated.
    my $other = FakeConn->new;
    identify($runner, $other, job_id => 'J2', job_try => 0, run_id => 'R1', pid => 666);
    ok(!@{$other->{controls}}, "a collector for a job with no termination intent is left alone");

    # A retry of J1 (new try) must NOT be terminated by a stale intent for the old try.
    # Try ordinals are 1-based (R10/#49): the first try is 1, the retry is 2.
    $runner->{terminated_jobs}{J1} = {job_try => 1, run_id => 'R1', reason => 'old try'};
    my $retry = FakeConn->new;
    identify($runner, $retry, job_id => 'J1', job_try => 2, run_id => 'R1', pid => 777);
    ok(!@{$retry->{controls}}, "a different try's collector is not terminated by a stale per-job intent");
    ok(exists $runner->{terminated_jobs}{J1}, "the stale intent for the old try is left intact on a try mismatch");
};

subtest announce_run_sweeps_terminated_jobs => sub {
    # M1: a per-job termination intent whose collector never connects is dropped when
    # the run ends, so a persistent runner does not accumulate them. An unrelated run's
    # intent is untouched.
    my $runner = mk_runner(running => {});
    $runner->{run_owners}{R1} = 1;    # skip the §4.2 purge so announce_run is self-contained
    $runner->{terminated_jobs}{J1} = {job_try => 0, run_id => 'R1', reason => 'x'};
    $runner->{terminated_jobs}{J2} = {job_try => 0, run_id => 'R2', reason => 'y'};

    $runner->announce_run('R1');

    ok(!exists $runner->{terminated_jobs}{J1}, "R1's per-job intent is swept at run end");
    ok(exists $runner->{terminated_jobs}{J2}, "an unrelated run's intent is left intact");
};

subtest c2_collector_reap_survives_eof => sub {
    # Ticket #28 C2: a passing job's pid->job reap entry (collector_reap) is recorded
    # at the pass decision and must SURVIVE the collector's EOF -- which clears job_pids
    # (the status map) -- so the later reap of the detached collector can still run A3.
    my $runner = mk_runner(running => {J1 => {file => 'a.t', run_id => 'R1', is_try => 0}});
    my $conn = FakeConn->new;
    identify($runner, $conn, job_id => 'J1', job_try => 0, run_id => 'R1', pid => 5555);

    # The collector reported a pass (captured on the conn entry), then EOFs.
    $runner->{collector_conns}{"$conn"}{final_state} = {pass => 1};
    $conn->close;
    $runner->collector_conn_eof($conn);

    is($runner->{collector_reap}{5555}{job_id}, 'J1', "collector_reap populated at pass, keyed by the collector pid");
    ok(!exists $runner->{job_pids}{J1}, "job_pids (status map) cleared at EOF");
    ok(exists $runner->{job_passed}{J1}, "job_passed retained for the post-pass A3 check");

    # Run end sweeps the reap entry so a never-reaped collector does not leak.
    $runner->{run_owners}{R1} = 1;    # skip the §4.2 purge so announce_run is self-contained
    $runner->announce_run('R1');
    ok(!exists $runner->{collector_reap}{5555}, "collector_reap swept at run end");
};

subtest handshake_records_job_pid => sub {
    # Ticket #28: a test collector reports its OWN pid on its identity handshake, and
    # the runner records it into job_pids for both run paths (the preload path no
    # longer reports a stage-side pid because the collector double-forks + detaches).
    my $runner = mk_runner(running => {});
    my $conn   = FakeConn->new;

    identify($runner, $conn, job_id => 'J9', job_try => 0, run_id => 'R1', pid => 4242);

    is($runner->{job_pids}{J9}, 4242, "collector pid from the handshake recorded in job_pids");
};

subtest post_pass_health_flag => sub {
    # The runner records that J1 reported a pass (decide_collector_outcome), then a
    # later non-zero health exit flags the suite (announce_run_health) while the test
    # stays a pass.
    my $runner = mk_runner(running => {});
    $runner->announce_run_health('R1', "collector malfunctioned after a pass");

    my $health = $runner->monitor->run_health;
    is(scalar(@$health), 1, "one suite-level health failure recorded");
    is($health->[0]{run_id}, 'R1', "health failure carries the run id");

    # The renderer fold marks the suite failed even with no failed tests.
    require Test2::Harness2::Renderer::Base;
    my $base = bless {}, 'Test2::Harness2::Renderer::Base';
    $base->{jobs}       = {};
    $base->{run_health} = $health;
    my $final = $base->compute_final;
    is($final->{pass}, 0, "the suite is FAILED by the post-pass health failure");
    ok($final->{health_errors}, "health error reasons surfaced");
    ok(!$final->{failed}, "no test is marked failed (the tests stayed green)");
};

subtest per_job_terminate_deadline_hard_kills => sub {
    # #135 finding 15: a collector terminated via a PER-JOB connect-timeout intent (no
    # run-level aborting_runs record) is still hard-killed if it does not comply within
    # the grace. _terminate_collector stamps a per-entry terminate_deadline, and
    # _enforce_terminate_grace falls back to it when there is no run-level intent.
    my $runner = mk_runner(running => {});

    # Spawn a harmless sleeper we own, so the group KILL lands on a real process. It
    # setsids so it leads its own process group -- the detached-collector shape the
    # enforcer's kill(-pid) targets -- and so the group KILL cannot reach the test.
    my $pid = fork // die "fork failed: $!";
    unless ($pid) { POSIX::setsid(); $0 = "t135-sleeper"; sleep 30; POSIX::_exit(0); }
    Time::HiRes::sleep(0.05);    # let the child setsid before we target its group

    my $conn = FakeConn->new;
    identify($runner, $conn, job_id => 'J1', job_try => 1, run_id => 'R1', pid => $pid);

    # Per-job termination (NOT a run-scoped abort): no aborting_runs intent exists.
    $runner->_terminate_collector($runner->{collector_conns}{"$conn"}, "connect timeout hard kill");
    ok(!$runner->{aborting_runs} || !keys %{$runner->{aborting_runs}}, "no run-level abort intent recorded");

    my ($entry) = grep { $_->{job_id} eq 'J1' } values %{$runner->{collector_conns}};
    ok(defined $entry->{terminate_deadline}, "a per-entry terminate_deadline was stamped");

    # Force the per-entry deadline into the past; the grace fallback must fire.
    $entry->{terminate_deadline} = mono_time - 1;
    $runner->_enforce_terminate_grace;

    ok($entry->{hard_killed}, "the non-complying collector was hard-killed via its per-entry deadline");

    # Observe the group signal actually reached the sleeper.
    my $reaped = 0;
    for (1 .. 100) { last if ($reaped = waitpid($pid, POSIX::WNOHANG)) == $pid; Time::HiRes::sleep(0.02); }
    is($reaped, $pid, "the spawned sleeper received the KILL and was reaped");
};

subtest decided_first_try_undef_matches_wire_one => sub {
    # #135 finding 2 (direct): mark_job_decided with a raw undef try (a first attempt
    # that never carried is_try) and job_already_decided with the wire try 1 (what the
    # collector sends) must resolve to the SAME two-level key.
    my $runner = mk_runner(running => {});
    $runner->mark_job_decided('JX', undef);
    ok($runner->job_already_decided('JX', 1), "undef try and wire-try-1 collapse to the same decided key");
    ok($runner->job_already_decided('JX', undef), "undef checks against the same normalized key");
    ok(!$runner->job_already_decided('JX', 2), "a genuine retry (try 2) is a distinct, undecided key");
};

done_testing;

use Test2::V0;
use POSIX ();
use Time::HiRes ();
# HARNESS-DURATION-SHORT

# Ticket TODO-28 C1+C2, end-to-end through the REAL run_scheduler_only loop:
#   C1 -- the scheduler-only runner reaps an UNWATCHED detached collector each tick
#         (it calls _bring_out_yer_dead; the loop never goes through IPC::wait).
#   C2 -- a non-zero HEALTH exit AFTER the job reported a pass is mapped back to the
#         job via the pid-keyed collector_reap map (which survives the collector's
#         EOF) and fires the A3 suite-health escalation (announce_run_health).
# A clean exit fires no A3. The subreaper REPARENTING itself is covered by
# t/AI/unit/Util_SubReaper.t; here we exercise the actual scheduler-only loop.
#
# Each experiment runs in a forked SUBJECT so the runner's waitpid(-1) only ever
# sees that subject's own child, never the test harness's processes. The subject
# encodes its checks in its exit status; the parent just asserts a clean exit.

use Test2::Harness2::Runner;
use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "This test requires forking" unless CAN_REALLY_FORK;

# A Runner subclass that stubs ONLY the socket/scheduler I/O, so run_scheduler_only
# runs its real Phase-2 loop and the real _bring_out_yer_dead / _check_if_dead_yet /
# _reaped_unwatched_pid / _check_post_pass_health against a hand-seeded reap map.
{
    package ReapHarnessRunner;
    our @ISA = ('Test2::Harness2::Runner');

    # This models a PRELOAD runner (detached collectors re-parent to it), so the
    # no-preload-scoped wind-down ports in run_scheduler_only stay off.
    sub _preload_root_hosts_stages { 1 }

    sub _ready_to_schedule        { 1 }
    sub service_io                { 0 }
    sub service_tick              { 0 }
    sub flush_submit_buffer       { 0 }
    sub stage_host_exited         { 0 }
    sub stage_host_errors         { [] }
    sub _handle_dead_preload_root { '' }
    sub stop_preload_stages       { 0 }
    sub settings                  { $_[0]->{settings} }
    sub watchdog                  { $_[0]->{watchdog} }
    sub state                     { $_[0]->{state} }

    sub announce_run_health {
        my ($self, $run_id, $reason) = @_;
        push @{$self->{health}} => {run_id => $run_id, reason => $reason};
        return;
    }
}

{
    package FakeReapSettings;
    sub new                 { bless {}, shift }
    sub runner              { $_[0] }
    sub preload_map_timeout { 10 }

    package FakeReapWatchdog;
    sub new            { bless {}, shift }
    sub abort_remaining { return }

    package FakeReapState;
    sub new { my ($c, %a) = @_; bless {target => $a{target}, ticks => 0, max => $a{max} // 3000}, $c }

    # Keep the loop running until the target child has been REAPED (kill 0 fails),
    # with a hard tick cap as a safety net so a regression can never hang the suite.
    sub done {
        my $self = shift;
        return 1 if ++$self->{ticks} >= $self->{max};
        return 0 if kill(0, $self->{target});
        return 1;
    }
}

# Fork a subject that: forks an unwatched detached child (a stand-in for a
# re-parented preload collector) which exits with $exit_code as its HEALTH status;
# seeds collector_reap{child} + job_passed for a passed job; drives the REAL
# run_scheduler_only; then checks the reap + A3 outcome. Returns the subject's exit
# code (0 == every check passed).
sub run_experiment {
    my ($exit_code, $expect_a3) = @_;

    my $subject = fork // die "fork: $!";
    if (!$subject) {
        my $child = fork // POSIX::_exit(80);
        if (!$child) {
            POSIX::setsid();                  # own session/group, like a detached collector
            Time::HiRes::sleep(0.15);         # briefly alive so the loop ticks before the reap
            POSIX::_exit($exit_code);
        }

        my $runner = bless {
            'collector_reap' => {$child => {job_id => 'J1', run_id => 'R1'}},
            'job_passed'     => {J1 => 'R1'},
            health           => [],
            settings         => FakeReapSettings->new,
            watchdog         => FakeReapWatchdog->new,
            state            => FakeReapState->new(target => $child),
            wait_time        => 0.01,
        }, 'ReapHarnessRunner';

        my $ok = eval { $runner->run_scheduler_only; 1 };
        POSIX::_exit(90) unless $ok;

        my $reaped   = kill(0, $child) ? 0 : 1;
        my $consumed = exists $runner->{collector_reap}{$child} ? 0 : 1;
        my $a3       = scalar @{$runner->{health}};

        POSIX::_exit(70) unless $reaped;      # the loop never reaped the detached child
        POSIX::_exit(71) unless $consumed;    # the reap map entry was not consumed
        if ($expect_a3) {
            POSIX::_exit(72) unless $a3 == 1;
            POSIX::_exit(73) unless $runner->{health}[0]{run_id} eq 'R1';
        }
        else {
            POSIX::_exit(74) unless $a3 == 0;
        }

        POSIX::_exit(0);
    }

    waitpid($subject, 0);
    return $? >> 8;
}

subtest post_pass_nonzero_health_fires_a3 => sub {
    is(run_experiment(1, 1), 0, "scheduler-only loop reaped the detached child, fired A3, consumed the reap map");
};

subtest clean_health_exit_no_a3 => sub {
    is(run_experiment(0, 0), 0, "scheduler-only loop reaped the detached child with no A3 on a clean exit");
};

done_testing;

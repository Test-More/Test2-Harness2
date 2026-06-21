use Test2::V0;
# HARNESS-DURATION-SHORT

# Ticket #28: the runner is a child subreaper, so it reaps re-parented detached
# preload collectors it never watched. _bring_out_yer_dead routes such an unwatched
# pid through _reaped_unwatched_pid, which reverse-maps it to a job via job_pids
# (the collector reported its own pid on its handshake) and runs the A3 post-pass
# health escalation. We drive the two helper methods directly against the REAL
# Runner methods via a tiny subclass that captures announce_run_health.

use Test2::Harness2::Runner;

{
    package FakeSubreaperRunner;
    our @ISA = ('Test2::Harness2::Runner');

    sub new {
        my ($class, %args) = @_;
        return bless {
            job_pids    => $args{job_pids}    // {},
            'job_passed' => $args{job_passed} // {},
            health      => [],
        }, $class;
    }

    # Capture instead of forwarding over the socket.
    sub announce_run_health {
        my ($self, $run_id, $reason) = @_;
        push @{$self->{health}} => {run_id => $run_id, reason => $reason};
        return;
    }
}

subtest detached_collector_post_pass_nonzero_flags_suite => sub {
    my $runner = FakeSubreaperRunner->new(
        job_pids    => {J1 => 5555},
        job_passed  => {J1 => 'R1'},
    );

    # The runner reaps pid 5555 (the detached collector) with a non-zero health exit.
    $runner->_reaped_unwatched_pid(5555, 256);    # exit code 1 (<<8)

    is(scalar(@{$runner->{health}}), 1, "a suite-level health failure was recorded");
    is($runner->{health}[0]{run_id}, 'R1', "health failure carries the run id");
    ok(!exists $runner->{job_pids}{J1}, "job_pids entry cleared once reaped");
};

subtest detached_collector_clean_exit_no_flag => sub {
    my $runner = FakeSubreaperRunner->new(
        job_pids    => {J1 => 5555},
        job_passed  => {J1 => 'R1'},
    );

    # A clean (zero) health exit after a pass is the normal case: no flag.
    $runner->_reaped_unwatched_pid(5555, 0);

    is(scalar(@{$runner->{health}}), 0, "a clean exit raises no health failure");
};

subtest unknown_pid_ignored => sub {
    my $runner = FakeSubreaperRunner->new(
        job_pids    => {J1 => 5555},
        job_passed  => {J1 => 'R1'},
    );

    # A pid that maps to no job (a benign plugin/3rd-party child) is ignored.
    $runner->_reaped_unwatched_pid(99999, 256);

    is(scalar(@{$runner->{health}}), 0, "an unmatched pid raises no health failure");
    is($runner->{job_pids}{J1}, 5555, "an unmatched reap leaves job_pids untouched");
};

subtest no_pass_no_flag => sub {
    # The collector exited non-zero but its job never reported a pass: A3 does not
    # fire (A3 is specifically a POST-PASS escalation).
    my $runner = FakeSubreaperRunner->new(
        job_pids    => {J1 => 5555},
        job_passed  => {},
    );

    $runner->_reaped_unwatched_pid(5555, 256);

    is(scalar(@{$runner->{health}}), 0, "a non-pass job raises no post-pass health failure");
    ok(!exists $runner->{job_pids}{J1}, "job_pids entry still cleared on reap");
};

done_testing;

use Test2::V0;
# HARNESS-DURATION-SHORT

# Ticket TODO-28: the runner is a child subreaper, so it reaps re-parented detached
# preload collectors it never watched. _bring_out_yer_dead routes such an unwatched
# pid through _reaped_unwatched_pid, which maps it to a job via the pid-keyed
# collector_reap map (recorded when the job reported a pass, and kept alive past the
# collector's EOF -- ticket TODO-28 C2 -- because job_pids, the status map, is cleared at
# that EOF) and runs the A3 post-pass health escalation. We drive the helper directly
# against the REAL Runner methods via a tiny subclass that captures announce_run_health.

use Test2::Harness2::Runner;

{
    package FakeSubreaperRunner;
    our @ISA = ('Test2::Harness2::Runner');

    sub new {
        my ($class, %args) = @_;
        return bless {
            'collector_reap' => $args{collector_reap} // {},
            'job_passed'     => $args{job_passed}     // {},
            health           => [],
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
        collector_reap => {5555 => {job_id => 'J1', run_id => 'R1'}},
        job_passed     => {J1 => 'R1'},
    );

    # The runner reaps pid 5555 (the detached collector) with a non-zero health exit.
    $runner->_reaped_unwatched_pid(5555, 256);    # exit code 1 (<<8)

    is(scalar(@{$runner->{health}}), 1, "a suite-level health failure was recorded");
    is($runner->{health}[0]{run_id}, 'R1', "health failure carries the run id");
    ok(!exists $runner->{collector_reap}{5555}, "collector_reap entry consumed once reaped");
};

subtest detached_collector_clean_exit_no_flag => sub {
    my $runner = FakeSubreaperRunner->new(
        collector_reap => {5555 => {job_id => 'J1', run_id => 'R1'}},
        job_passed     => {J1 => 'R1'},
    );

    # A clean (zero) health exit after a pass is the normal case: no flag.
    $runner->_reaped_unwatched_pid(5555, 0);

    is(scalar(@{$runner->{health}}), 0, "a clean exit raises no health failure");
    ok(!exists $runner->{collector_reap}{5555}, "collector_reap entry consumed even on a clean reap");
};

subtest unknown_pid_ignored => sub {
    my $runner = FakeSubreaperRunner->new(
        collector_reap => {5555 => {job_id => 'J1', run_id => 'R1'}},
        job_passed     => {J1 => 'R1'},
    );

    # A pid that maps to no collector_reap entry (a benign plugin/3rd-party child) is
    # ignored, and an unrelated entry is left intact.
    $runner->_reaped_unwatched_pid(99999, 256);

    is(scalar(@{$runner->{health}}), 0, "an unmatched pid raises no health failure");
    is($runner->{collector_reap}{5555}{job_id}, 'J1', "an unmatched reap leaves collector_reap untouched");
};

subtest no_pass_no_flag => sub {
    # A job that never reported a pass has NO collector_reap entry (it is recorded only
    # at the pass decision), so reaping its collector is a no-op: A3 is a POST-PASS
    # escalation only.
    my $runner = FakeSubreaperRunner->new(
        collector_reap => {},
        job_passed     => {},
    );

    $runner->_reaped_unwatched_pid(5555, 256);

    is(scalar(@{$runner->{health}}), 0, "a non-pass job raises no post-pass health failure");
};

done_testing;

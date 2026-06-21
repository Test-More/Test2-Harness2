package Test2::Harness2::Runner::Watchdog;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Object::HashBase qw{
    <runner
    +aborted
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Watchdog - Runner-side authority that aborts jobs which
will never complete, the transient successor to the gatherer's stalled-job
detection.

=head1 DESCRIPTION

On the transient path there is no yath-side gatherer: the runner is the
completion / stalled / timeout / verdict authority. Run-level timeout aborts
already live in the scheduler tick (L<Test2::Harness2::Runner::State> resource
timeout). This watchdog folds in the remaining gatherer duty -- aborting a job
that was dispatched/running but whose collector will never report completion --
over the runner's canonical state.

It is deliberately B<conservative>, matching the gatherer's actual semantics: the
1.0 gatherer only aborted stalled jobs once the runner/scheduler process itself
was gone (C<kill(0)> failed) -- its strongest "this can never finish" signal. On
the transient path the runner B<is> that authority and is alive for the whole
run, so the only genuinely unfinishable states are the run B<winding down> with
tasks still tracked as running (a stage that died mid-run, or a signal-driven
shutdown), and a dispatch the runner B<knows> failed because the target stage was
already gone (C<abort_job>, called from C<dispatch_pending>). Both are confirmed
unfinishable: in the wind-down case the run loop is ending, and in the failed
dispatch case the send was a proven no-op so no stage will ever report the job.
Speculative mid-run per-stage death polling is still intentionally avoided -- the
nested stage topology makes "is this stage's process gone?" unreliable,
and a healthy stage's jobs are completed through the runner's normal reap /
C<set_proc_exit> path.

When the watchdog aborts a job it synthesizes the outcome into canonical state:
it stops the task in the scheduler (releasing its slot / resources) and announces
an C<aborted> runner-job mutation, which subscribers (the command-side renderer
driver) fold and roll up as failed -- the same effect the gatherer's synthetic
C<harness_job_exit{aborted}> / C<harness_job_end{fail}> had.

=head1 SYNOPSIS

    my $wd = Test2::Harness2::Runner::Watchdog->new(runner => $runner);

    # On run wind-down, abort anything still unfinished:
    $wd->abort_remaining("Runner shut down before this job completed");

=cut

sub init ($self) {
    croak "'runner' is a required attribute" unless $self->{+RUNNER};
    $self->{+ABORTED} = {};
    return;
}

=head1 PUBLIC METHODS

=over 4

=item $wd->abort_remaining($reason)

=item $wd->abort_remaining($reason, run_id =E<gt> $run_id)

Abort every still-running task that has not reported completion, attributing the
optional C<$reason>. Called when the runner is winding the run down so a job
whose collector never finalized still rolls up as failed instead of silently
vanishing. Each job is aborted at most once. With a C<run_id> the abort is scoped
to that one run's jobs (the owner-drop abort path, which must not touch other runs
on a persistent runner).

=item $wd->abort_job($job_id, $task, $reason)

Abort one specific still-tracked job, attributing C<$reason>. Used the moment a
dispatch to a stage is known to have failed (the stage was gone, so the send was
a no-op): the task is already marked running and has consumed resources but no
stage will ever report its completion, so it would hang the run. This synthesizes
its abort into canonical state right away -- releasing its slot / resources and
rolling it up as failed -- instead of waiting for run wind-down. Each job is
aborted at most once.

=back

=cut

sub abort_job ($self, $job_id, $task, $reason = undef) {
    return if $self->{+ABORTED}{$job_id};
    $self->_abort_job($job_id, $task, $reason // "Runner could not dispatch this job to its stage");
    return;
}

sub abort_remaining ($self, $reason = undef, %params) {
    my $runner = $self->{+RUNNER};
    return unless $runner->rootpid == $$;

    # Optionally scope to one run: the owner-drop abort path (ticket #12 /
    # ARCHITECTURE.md §4.2) aborts only the dropped run's jobs, leaving other runs on
    # a persistent runner untouched. Wind-down passes no run_id and aborts them all.
    my $only_run = $params{run_id};

    my $running = $runner->state->running_tasks // {};

    for my $job_id (keys %$running) {
        next if $self->{+ABORTED}{$job_id};
        my $task = $running->{$job_id};
        next if defined($only_run) && ($task->{run_id} // '') ne $only_run;
        $self->_abort_job($job_id, $task, $reason // "Runner shut down before this job completed");
    }

    return;
}

=head1 PRIVATE METHODS

=over 4

=item $self->_abort_job($job_id, $task, $reason)

Synthesize the abort into canonical state: stop the task in the scheduler (so its
slot / resources release) and announce an C<aborted> runner-job mutation carrying
the file + reason, so subscribers fold it as a failed completion. Stopping the
task is best-effort -- a task already removed by a racing reap is fine.

=back

=cut

sub _abort_job ($self, $job_id, $task, $reason) {
    my $runner = $self->{+RUNNER};

    $self->{+ABORTED}{$job_id} = 1;

    # Converge with the EOF decision (ARCHITECTURE.md §5.4): mark this
    # (job_id, job_try) decided in the runner's shared fire-once ledger so the
    # collector's later connection EOF is a no-op (it must not re-decide / double
    # announce). The runner keeps the ledger; the watchdog is the other writer.
    $runner->mark_job_decided($job_id, $task->{is_try})
        if $runner->can('mark_job_decided');

    # Best-effort slot / resource release; a task a racing reap already stopped
    # leaves stop_task croaking "not running", which is not an error here.
    my $ok = eval { $runner->state->stop_task($job_id); 1 };

    # Announce the abort as a runner-originated mutation so subscribers (the
    # command-side driver) fold it and roll it up as failed, mirroring the
    # gatherer's synthetic harness_job_exit{aborted} / harness_job_end{fail}.
    $runner->announce_job(
        $job_id, 'aborted',
        file    => $task->{file},
        run_id  => $task->{run_id},
        details => $reason,
    );

    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

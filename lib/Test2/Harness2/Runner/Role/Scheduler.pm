package Test2::Harness2::Runner::Role::Scheduler;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

# Constant-only slots: this role shares the runner's hashref. Declaring the slot
# keys it touches as HashBase constants gives compile-time/grep safety on the
# bare-string keys without changing the slots themselves (the constant is the
# lowercased name). The owning runner declares the same slots; the values match.
use Test2::Harness2::Util::HashBase qw{
    +rootpid
    +signal
    +resource_timeout
};

requires qw/state announce_run dispatch_pending service_stopped/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Role::Scheduler - The runner's in-process scheduler
tick.

=head1 DESCRIPTION

This role carries the scheduler half of L<Test2::Harness2::Runner>: the
per-service-loop tick that advances the in-process
L<Test2::Harness2::Runner::State> object. The scheduler is an in-runner object
ticked on the same cadence as the socket I/O, and these methods are the entry
points the run loop calls.

It is composed into the runner alongside
L<Test2::Harness2::Role::Service> and
L<Test2::Harness2::Runner::Role::Service::Handlers>; every method here is a
method on the runner C<$self> and shares its hashref slots and its other
composed methods (C<state>, C<announce_run>, C<dispatch_pending>).

=head1 SYNOPSIS

    package Test2::Harness2::Runner;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Scheduler';

=head1 PUBLIC METHODS

=over 4

=item $self->service_tick

Called each service-loop iteration. Translates a socket C<stop> request into the
runner's own shutdown signal, then advances the scheduler via
C<scheduler_tick>.

=item $self->scheduler_tick

Advance the in-process scheduler: poll + advance the state, announce a finished
run, dispatch started tasks to stage sockets, enforce the collector-connect
timeout + the terminate hard-kill grace, and enforce the resource timeout. A throw
out of any of these is a real in-process bug and is left to propagate — the
scheduler fails fast. Resources that need to tolerate transient errors must catch
them inside their own C<tick()>.

=back

=cut

sub service_tick {
    my $self = shift;

    # A 'stop' request over runner.socket asks the run loop to wind down. The
    # role's request_handler_stop sets service_stopped; translate that into the
    # runner's own shutdown signal so the run loop (run_stage) terminates through
    # end_test_loop.
    $self->{+SIGNAL} //= 'TERM' if $self->service_stopped;

    # The scheduler is an in-runner object: advance it here, on the
    # same service-loop cadence the socket I/O runs on.
    $self->scheduler_tick;

    return;
}

sub scheduler_tick {
    my $self = shift;

    # Once we are winding down there is no point advancing the scheduler.
    return if $self->{+SIGNAL};

    my $state = $self->state;

    # Fail fast: the scheduler is in-runner code now (the separate-process retry
    # rationale died with the IPC model). A throw out of advance/dispatch is a
    # real in-process bug and is left to propagate. Resources that need to
    # tolerate transient errors must catch them inside their own tick().

    while (1) {
        next if $state->advance;
        last;
    }

    # Announce every run that RETIRED during this advance (#135 finding 28). The state
    # records each retirement as an event (clear_finished_run), so a run activated AND
    # retired within this one loop -- an empty run, a pre-stopped run, an abort -- is
    # still announced; a before/after ACTIVE_RUN slot diff would have missed it,
    # dropping its harness_run_end (hanging a subscriber) and leaking it on the
    # owner-drop leg. take_retired_runs drains destructively, and announce_run's own
    # announced_runs ledger suppresses any duplicate, so each run is announced once.
    $self->announce_run($_) for $state->take_retired_runs;

    # Hand any task the scheduler just started, whose run-stage
    # is a socketed preload stage (i.e. not this root process's own stage), out
    # over the registered channel that stage opened to us (service_send by peer
    # identity, not a fresh dial to preload-<stage>.socket). Tasks for the root's
    # own stage stay in the task list for the root's own run_job (the no-preload
    # path, where the root forks tests itself). This runs on the persistent path
    # too (its forked stages are dispatch services).
    $self->dispatch_pending;

    # Enforce the collector-connect timeout (a dispatched/running job whose
    # collector never connected) and the hard-kill grace for terminated collectors
    # that did not comply (ARCHITECTURE.md §5.4). Both are runner-visible failures
    # the fire-once ledger still guards, so they never double-decide a job.
    $self->_enforce_collector_connect_timeout;
    $self->_enforce_terminate_grace;

    # Live-connection-safe deferred sweep of retired runs' per-job ledgers
    # (#135 finding 3): a job is swept only once its collector connection has closed
    # and a grace has elapsed since the run retired, so a late EOF or a
    # post-retirement reap never reads a ledger already gone.
    $self->_flush_run_ledger_sweeps;

    if (my $idle = $state->resource_timeout($self->{+RESOURCE_TIMEOUT})) {
        print STDERR "\n\nyath: Resource timeout after ${idle}s with no tests able to start. Aborting.\n";
        print STDERR "There are pending tests but resources have not become available.\n";
        print STDERR "Use --resource-timeout to adjust or disable (0) this timeout.\n\n";
        $state->truncate();
        $self->{+SIGNAL} = 'TERM';
    }

    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

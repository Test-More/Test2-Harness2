package Test2::Harness2::Runner::Role::Scheduler;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

requires qw/state announce_run dispatch_pending service_stopped/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Role::Scheduler - The runner's in-process scheduler
tick.

=head1 DESCRIPTION

This role carries the scheduler half of L<Test2::Harness2::Runner>: the
per-service-loop tick that advances the in-process
L<Test2::Harness2::Runner::State> object. The scheduler used to be a separate
process polling C<dispatch.jsonl> under a flock (chunk 5b); it is now an
in-runner object ticked on the same cadence as the socket I/O, and these methods
are the entry points the run loop calls.

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

=item $int = $self->SCHEDULER_MAX_ERRORS

How many consecutive scheduler-logic failures the runner tolerates before it
aborts the run.

=item $self->scheduler_tick

Advance the in-process scheduler: poll + advance the state, announce a finished
run, dispatch started tasks to stage sockets, and enforce the resource timeout.
Consecutive failures are counted and the run is aborted after
C<SCHEDULER_MAX_ERRORS>.

=back

=cut

sub service_tick {
    my $self = shift;

    # A 'stop' request over runner.socket asks the run loop to wind down. The
    # role's request_handler_stop sets service_stopped; translate that into the
    # runner's own shutdown signal so the run loop (run_stage) terminates through
    # end_test_loop.
    $self->{'signal'} //= 'TERM' if $self->service_stopped;

    # The scheduler is an in-runner object (chunk 5b): advance it here, on the
    # same service-loop cadence the socket I/O runs on, instead of in a separate
    # process polling dispatch.jsonl under a flock.
    $self->scheduler_tick;

    return;
}

# How many consecutive scheduler-logic failures the runner tolerates before it
# gives up and aborts the run. A scheduler used to be a separate process that
# could die and be detected via waitpid; now that it is in-runner code, a
# failure (e.g. a resource that dies in tick()) surfaces here directly. We retry
# a few times so a transient error self-heals, then abort cleanly with a useful
# diagnostic rather than spinning or silently hanging.
sub SCHEDULER_MAX_ERRORS { 5 }

sub scheduler_tick {
    my $self = shift;

    # Only the root runner process schedules; forked stage children do not.
    return unless $self->{'rootpid'} == $$;

    # Once we are winding down there is no point advancing the scheduler.
    return if $self->{'signal'};

    my $state = $self->state;

    my $ok = eval {
        $state->poll;

        # Track the active run across the advance so we can announce its end the
        # moment it leaves the active slot (chunk 6.1-2 per-run completion). The
        # run is recorded once it becomes active and announced once it clears.
        my $before = $state->run ? $state->run->run_id : undef;
        $self->{'active_run'} //= $before if defined $before;

        while (1) {
            next if $state->advance;
            last;
        }

        my $after = $state->run ? $state->run->run_id : undef;
        if (defined $self->{'active_run'} && (!defined($after) || $after ne $self->{'active_run'})) {
            $self->announce_run($self->{'active_run'});
            $self->{'active_run'} = $after;
        }

        # Chunk 5d/6.1-2: hand any task the scheduler just started, whose run-stage
        # is a socketed preload stage (i.e. not this root process's own stage), out
        # to that stage's preload-<stage>.socket. Tasks for the root's own stage
        # stay in the task list for the root's own run_job (the no-preload path,
        # where the root forks tests itself). This now runs on the persistent path
        # too (its forked stages are dispatch services).
        $self->dispatch_pending;

        if (my $idle = $state->resource_timeout($self->{'resource_timeout'})) {
            print STDERR "\n\nyath: Resource timeout after ${idle}s with no tests able to start. Aborting.\n";
            print STDERR "There are pending tests but resources have not become available.\n";
            print STDERR "Use --resource-timeout to adjust or disable (0) this timeout.\n\n";
            $state->truncate();
            $self->{'signal'} = 'TERM';
        }

        1;
    };

    if ($ok) {
        $self->{'scheduler_errors'} = 0;
        return;
    }

    my $err   = $@;
    my $count = ++$self->{'scheduler_errors'};
    my $max   = $self->SCHEDULER_MAX_ERRORS;
    print STDERR "\n$$ $0 Scheduler error ($count/$max): $err\n";

    if ($count >= $max) {
        print STDERR "$$ $0 Scheduler aborting after $count consecutive errors.\n";
        $self->{'signal'} //= 'TERM';
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

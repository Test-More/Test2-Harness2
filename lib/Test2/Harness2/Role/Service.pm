package Test2::Harness2::Role::Service;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep/;

use Role::Tiny;

requires 'tick';
requires 'should_stop';

my @BACKOFF = (0.05, 0.1, 0.5, 1);

sub run {
    my $self = shift;

    local $SIG{USR1} = sub { };
    $self->on_start if $self->can('on_start');

    my $idx = 0;
    until ($self->should_stop) {
        my $did_work = $self->tick;

        if ($did_work) {
            $idx = 0;
            next;
        }

        sleep($BACKOFF[$idx]);
        $idx++ if $idx < $#BACKOFF;
    }

    $self->on_stop if $self->can('on_stop');
    return;
}

sub wake { kill 'USR1', $_[0] || $$ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Service - Role for long-lived harness services
(scheduler, launchers, resource services, preload services).

=head1 DESCRIPTION

A service is a loop. Each iteration:

=over 4

=item *

Calls C<should_stop>. If it returns true, the loop exits.

=item *

Calls C<tick>. If C<tick> returns a true value the loop immediately
runs another iteration; otherwise it sleeps with backoff before the
next iteration.

=item *

Sleeps for C<0.05s>, then C<0.1s>, C<0.5s>, then C<1s> as the
backoff steps. The backoff resets to C<0.05s> the next time C<tick>
reports work done. The sleep uses L<Time::HiRes/sleep>, which
returns early on signal -- so a C<SIGUSR1> from another process
breaks the sleep immediately and the next iteration sees the new
work.

=back

Services install a no-op C<SIGUSR1> handler for the lifetime of the
loop so the sleep can be woken without aborting the process. The
C<wake> helper sends C<SIGUSR1> to a target pid.

=head1 REQUIRED METHODS

=over 4

=item $did_work = $service->tick

One iteration of the service's main work. Returning a true value
asks the loop to run another iteration immediately. Returning a
false value asks for the backoff sleep before the next iteration.

=item $bool = $service->should_stop

Return true to exit the loop cleanly. Polled at the top of every
iteration.

=back

=head1 OPTIONAL METHODS

=over 4

=item $service->on_start

Called once at the top of C<run>, after the C<SIGUSR1> handler is
installed. Use it to publish the C<starting>/C<up> state row, etc.

=item $service->on_stop

Called once just before C<run> returns. Use it to publish a
terminal state row, close handles, etc.

=back

=head1 PUBLIC METHODS

=over 4

=item $service->run

Run the service loop until C<should_stop> returns true. Drives
C<tick>, the backoff schedule, and the C<SIGUSR1>-interruptible
sleep.

=item wake($pid)

Send C<SIGUSR1> to C<$pid>. Convenience for callers that have just
written work into the database and want to nudge the addressee.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut

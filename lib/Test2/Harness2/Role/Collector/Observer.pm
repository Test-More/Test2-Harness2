package Test2::Harness2::Role::Collector::Observer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny;

requires 'observe_event';

sub startup  { () }
sub shutdown { () }

sub set_process_info { }
sub set_ipcm_info    { }
sub set_auditor      { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Collector::Observer - Role for observers that
watch the collector event stream and take side-effecting action.

=head1 DESCRIPTION

Observers sit between the auditor and the loggers in the collector
pipeline. They see every event after the auditor has had a chance to
enrich it (so any facets the auditor adds, such as
C<harness_job_exit>, are visible), and may inject additional events
that loggers then pick up.

Unlike auditors, observers are plural -- a collector may carry zero
or more of them. Unlike loggers, they are expected to take action
beyond writing the event: typically sending IPC messages when the
stream crosses a threshold of interest (first failing assertion,
process exit, etc.).

Observers behave like auditors on the event stream: each
observe_event call takes one event and returns a list -- normally
the incoming event (unchanged or transformed) plus any events the
observer wants to inject. Observers are chained in listed order;
observer N receives what observer N-1 returned, one event at a
time. An observer may drop an event by returning an empty list.

=head1 SYNOPSIS

    package My::Observer;
    use strict;
    use warnings;

    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Collector::Observer';

    sub observe_event {
        my ($self, $event) = @_;
        # inspect $event, fire IPC messages on interesting conditions,
        # return the event (normally unchanged) plus any synthesized
        # events to inject into the downstream stream.
        return ($event);
    }

    1;

=head1 REQUIRED METHODS

=over 4

=item @events = $observer->observe_event($event)

Given a single L<Test2::Harness2::Event>, return the list of
events to hand downstream. Normally this means returning
C<$event> itself plus zero or more events the observer wants to
inject. Returning an empty list drops the event from the stream.
The same contract as L<Test2::Harness2::Role::Auditor/audit_event>;
the collector pipelines observers in listed order, so observer N
sees whatever observer N-1 returned.

=back

=head1 PROVIDED METHODS

=over 4

=item @events = $observer->startup($collector)

Called once on each observer, after the auditor's startup hook
has run but before any auditor-startup events reach observe_event.
May return zero or more events; the collector forwards them
directly to the loggers after the auditor-startup events have
finished flowing through the observer chain (observer-startup
events do not themselves go through observe_event). Default:
empty list.

=item @events = $observer->shutdown($collector)

Called once, after the main collection loop exits, before the
loggers shut down. Auditor shutdown fires first so its events can
flow through every observer's observe_event; each observer's
shutdown events are forwarded straight to the loggers. Loggers
then receive the full accumulated stream before their own
shutdown runs. Default: empty list.

=item $observer->set_process_info(%info)

Stamp run / job / try identifiers onto a blessed observer instance
that was passed in pre-constructed. Default no-op.

=item $observer->set_ipcm_info($info)

Stamp the active IPC::Manager info onto a blessed observer instance.
Default no-op.

=item $observer->set_auditor($auditor)

Let the observer consult the auditor during observation. Default
no-op; observers that need auditor state should override.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

package Test2::Harness2::Collector::Role::Processor;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'process_event';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Role::Processor - Role implemented by collector
event processors.

=head1 DESCRIPTION

A processor is the optional middle stage of the collector pipeline. The
collector hands it one parsed L<Test2::Harness2::Event> at a time; the
processor returns the list of events that should actually be written to the
events file. That list may be empty (drop the event), the same single event,
or several events (the original plus synthesized ones).

No processor ships yet; this role only pins the contract the collector calls
against. When a processor is absent the collector writes each parsed event
straight through.

=head2 Compressed-form contract

The collector caches the on-wire zstd frame of each message burst on the
event's C<compressed_form> slot and, when that slot is present, writes the
frame to the events file verbatim instead of re-encoding. A processor that
modifies an event it returns B<must> C<delete> the event's C<compressed_form>
slot so the collector re-encodes the changed event rather than writing the
stale frame.

=head1 REQUIRED METHODS

=over 4

=item @events = $processor->process_event($event)

Take a single L<Test2::Harness2::Event> and return the list of events to
write. Return an empty list to drop the event.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

package Test2::Harness2::Collector::Role::Parser;
use strict;
use warnings;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'parse_io';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Role::Parser - Role implemented by collector parsers.

=head1 DESCRIPTION

Parsers sit at the front of the collector pipeline. The collector reads bytes
off the collected process's STDOUT and STDERR pipes and hands each line (or
each pre-decoded event burst) to the parser; the parser turns the input into
zero or one L<Test2::Harness2::Event> objects which are then passed downstream
to the optional auditor and on to the recorder.

This role pins the single method the collector requires from a parser:
C<parse_io>. Implementations may add their own attributes and helpers.

=head1 REQUIRED METHODS

=over 4

=item $event = $parser->parse_io(%params)

Turn one unit of input into one event (or C<undef> when there is nothing to
emit). Named parameters always include C<stream> (C<'stdout'> or C<'stderr'>)
and at least one of:

=over 4

=item line => $string

A single line of text (no trailing newline). The parser builds a fresh
L<Test2::Harness2::Event> describing the line.

=item event => $event_or_hashref

A pre-decoded JSON message burst lifted off the wire. May be a
L<Test2::Harness2::Event> instance or a plain hashref; implementations
should accept either.

=item compressed => $zstd_bytes

The original zstd-compressed bytes of a message burst, for recorders that
want to fast-path the on-disk write without re-encoding.

=back

Returning C<undef> tells the collector this input did not produce an event.

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

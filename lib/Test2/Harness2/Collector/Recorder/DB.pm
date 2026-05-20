package Test2::Harness2::Collector::Recorder::DB;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Object::HashBase;
use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Recorder';

sub record_event    { croak "Test2::Harness2::Collector::Recorder::DB is not yet implemented" }
sub record_state    { croak "Test2::Harness2::Collector::Recorder::DB is not yet implemented" }
sub record_exit     { croak "Test2::Harness2::Collector::Recorder::DB is not yet implemented" }
sub record_artifact { croak "Test2::Harness2::Collector::Recorder::DB is not yet implemented" }
sub finalize        { croak "Test2::Harness2::Collector::Recorder::DB is not yet implemented" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Recorder::DB - Database-backed recorder
(not yet implemented).

=head1 DESCRIPTION

Placeholder implementation of L<Test2::Harness2::Collector::Role::Recorder>.
Carries the role surface so the collector pipeline can be wired against
it; every method croaks until the database row layer is in place.

=head1 PUBLIC METHODS

=over 4

=item record_event / record_state / record_exit / record_artifact / finalize

All croak. Use L<Test2::Harness2::Collector::Recorder::Files> for now if
you need a working recorder.

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

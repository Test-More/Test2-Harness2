package Test2::Harness2::Row::ServiceState;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Row';
use Object::HashBase qw{
    <service_state_id
    <service_id
    <stamp
    <status
    <content
};

sub TABLE        { 'service_state' }
sub PRIMARY_KEY  { 'service_state_id' }
sub COLUMNS      { qw/service_state_id service_id stamp status content/ }
sub JSON_COLUMNS { qw/content/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Row::ServiceState - Row object for the C<service_state>
table.

=head1 DESCRIPTION

Append-only state log for a service; most recent row per
C<service_id> wins. C<content> is a JSON payload the service writes
to publish state to readers.

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

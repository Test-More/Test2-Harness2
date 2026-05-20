package Test2::Harness2::Row::Requests;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Row';
use Object::HashBase qw{
    <request_id
    <service_id
    <requested
    <completed
    <finalized
    <payload
    <response
};

sub TABLE        { 'requests' }
sub PRIMARY_KEY  { 'request_id' }
sub COLUMNS      { qw/request_id service_id requested completed finalized payload response/ }
sub JSON_COLUMNS { qw/payload response/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Row::Requests - Row object for the C<requests> table.

=head1 DESCRIPTION

One row per request directed at a service. Unified shape for both
request/response and fire-and-forget notification flows; the latter
leave C<response> C<NULL> and may be deleted on ack.

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

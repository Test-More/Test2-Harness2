package Test2::Harness2::Runner::Run::Resource;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    +_handle
    <resource_id
    <run_id
    <type
    <stamp
    <payload
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Row';

sub TABLE        { 'resources' }
sub PRIMARY_KEY  { 'resource_id' }
sub COLUMNS      { qw/resource_id run_id type stamp payload/ }
sub JSON_COLUMNS { qw/payload/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Run::Resource - Row object for the C<resources> table.

=head1 DESCRIPTION

One row per resource sample. C<type> is a short identifier
(C<'cpu'>, C<'memory'>, custom names). C<payload> is producer-defined
JSON. Indexed by C<(run_id, type, stamp)> for sequential
single-timeseries reads.

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

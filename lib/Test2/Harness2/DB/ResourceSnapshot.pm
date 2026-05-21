package Test2::Harness2::DB::ResourceSnapshot;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <resource_snapshot_id
    <resource_id
    <stamp
    <payload
};
sub TABLE        { 'resource_snapshots' }
sub PRIMARY_KEY  { 'resource_snapshot_id' }
sub COLUMNS      { qw/resource_snapshot_id resource_id stamp payload/ }
sub JSON_COLUMNS { qw/payload/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DB::ResourceSnapshot - Row object for the
C<resource_snapshots> table.

=head1 DESCRIPTION

One row per resource sample. C<payload> is the producer-defined JSON
sample body. C<resource_id> points at the
L<Test2::Harness2::DB::Resource> row whose C<class> identifies
the sample's type. Indexed by C<(resource_id, stamp)> for sequential
single-resource reads.

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

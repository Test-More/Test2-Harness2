package Test2::Harness2::Project::Version;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <version_id
    <project_id
    <version
};
sub TABLE       { 'versions' }
sub PRIMARY_KEY { 'version_id' }
sub COLUMNS     { qw/version_id project_id version/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Project::Version - Row object for the C<versions> table.

=head1 DESCRIPTION

One row per project version. Deduplicated by C<(project_id, version)>.

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

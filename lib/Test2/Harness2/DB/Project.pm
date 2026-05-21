package Test2::Harness2::DB::Project;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <project_id
    <name
};
sub TABLE       { 'projects' }
sub PRIMARY_KEY { 'project_id' }
sub COLUMNS     { qw/project_id name/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DB::Project - Row object for the C<projects> table.

=head1 DESCRIPTION

One row per project. Deduplicated by name.

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

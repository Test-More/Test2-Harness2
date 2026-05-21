package Test2::Harness2::Project::TestFile;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    +_handle
    <test_file_id
    <project_id
    <relative
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Row';

sub TABLE       { 'test_files' }
sub PRIMARY_KEY { 'test_file_id' }
sub COLUMNS     { qw/test_file_id project_id relative/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Project::TestFile - Row object for the C<test_files> table.

=head1 DESCRIPTION

One row per test-file path under a project. Deduplicated by
C<(project_id, relative)>.

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

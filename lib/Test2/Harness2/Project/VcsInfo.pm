package Test2::Harness2::Project::VcsInfo;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <vcs_info_id
    <project_id
    <branch
    <revision
    <dirty
};
sub TABLE       { 'vcs_info' }
sub PRIMARY_KEY { 'vcs_info_id' }
sub COLUMNS     { qw/vcs_info_id project_id branch revision dirty/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Project::VcsInfo - Row object for the C<vcs_info> table.

=head1 DESCRIPTION

One row per (project, branch, revision, dirty) tuple. Optional
companion to L<Test2::Harness2::Project::Version> for runs done during
development. C<Test2::Harness2> never auto-detects this; the
queueing tool fills in the values.

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

package Test2::Harness2::DB::Artifact;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <artifact_id
    <collector_id
    <filename
    <content
    <local_path
};
sub TABLE       { 'artifacts' }
sub PRIMARY_KEY { 'artifact_id' }
sub COLUMNS     { qw/artifact_id collector_id filename content local_path/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DB::Artifact - Row object for the C<artifacts> table.

=head1 DESCRIPTION

One row per file produced by a collector. Exactly one of C<content>
(inline bytes) and C<local_path> (path on disk) is non-null at any
time; the recorder migrates C<local_path> bytes into C<content> on
finalize.

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

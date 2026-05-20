package Test2::Harness2::Row::Launches;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Row';
use Object::HashBase qw{
    <launch_id
    <launcher_id
    <job_id
    <requested
    <started
};

sub TABLE       { 'launches' }
sub PRIMARY_KEY { 'launch_id' }
sub COLUMNS     { qw/launch_id launcher_id job_id requested started/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Row::Launches - Row object for the C<launches> table.

=head1 DESCRIPTION

One row per scheduler-launcher handoff. The scheduler inserts with
C<requested> set; the launcher fills in C<started> after it starts the
process.

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

package Test2::Harness2::Runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    +_handle
    <runner_id
    <instance_id
    <pid
    <started
    <finished
    <finalized
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Row';

sub TABLE       { 'runners' }
sub PRIMARY_KEY { 'runner_id' }
sub COLUMNS     { qw/runner_id instance_id pid started finished finalized/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner - Row object for the C<runners> table.

=head1 DESCRIPTION

One row per runner process under a harness instance.

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

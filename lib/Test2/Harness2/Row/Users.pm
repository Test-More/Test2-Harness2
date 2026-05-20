package Test2::Harness2::Row::Users;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Row';
use Object::HashBase qw{
    <user_id
    <name
    <email
};

sub TABLE       { 'users' }
sub PRIMARY_KEY { 'user_id' }
sub COLUMNS     { qw/user_id name email/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Row::Users - Row object for the C<users> table.

=head1 DESCRIPTION

One row per known user. Deduplicated by C<name>.

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

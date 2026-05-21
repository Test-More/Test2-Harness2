package Test2::Harness2::Runner::Service;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    +_handle
    <service_id
    <collector_id
    <runner_id
    <run_id
    <name
    <class
    <pid
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Row';

sub TABLE       { 'services' }
sub PRIMARY_KEY { 'service_id' }
sub COLUMNS     { qw/service_id collector_id runner_id run_id name class pid/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Service - Row object for the C<services> table.

=head1 DESCRIPTION

One row per service. Name is unique per C<(runner_id, run_id)>. The
C<pid> column carries the service process's pid so other processes
can wake its poll-loop with C<SIGUSR1>.

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

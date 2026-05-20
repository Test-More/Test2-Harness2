package Test2::Harness2::Row::Launchers;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Row';
use Object::HashBase qw{
    <launcher_id
    <runner_id
    <run_id
    <collector_id
    <name
    <class
    <spec
    <pid
    <spawn_socket
};

sub TABLE        { 'launchers' }
sub PRIMARY_KEY  { 'launcher_id' }
sub COLUMNS      {
    qw/launcher_id runner_id run_id collector_id name class spec pid spawn_socket/
}
sub JSON_COLUMNS { qw/spec/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Row::Launchers - Row object for the C<launchers> table.

=head1 DESCRIPTION

One row per launcher: its class, JSON construction spec, owning
collector / runner / (optional) run, the pid for C<SIGUSR1> wake-ups,
and a C<spawn_socket> path when the launcher supports spawn.

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

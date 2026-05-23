package Test2::Harness2::DB::Preload;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <preload_id
    <runner_id
    <run_id
    <collector_id
    <name
    <class
    <spec
    <pid
    <socket
};
sub TABLE        { 'preloads' }
sub PRIMARY_KEY  { 'preload_id' }
sub COLUMNS      {
    qw/preload_id runner_id run_id collector_id name class spec pid socket/
}
sub JSON_COLUMNS { qw/spec/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DB::Preload - Row object for the C<preloads> table.

=head1 DESCRIPTION

One row per preload service: its class, JSON construction spec, owning
collector / runner / (optional) run, the pid for C<SIGUSR1> wake-ups,
and the Unix socket path the preload service listens on for C<launch>
and C<spawn> requests.

Regular launchers (C<ForkExec>, C<Win32>, C<Default>) are in-process
objects owned by the scheduler and do B<not> have rows in this table.
See C<ARCHITECTURE.md> section 7 and section 10.

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

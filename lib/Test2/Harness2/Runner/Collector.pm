package Test2::Harness2::Runner::Collector;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    +_handle
    <collector_id
    <runner_id
    <name
    <pid
    <watched
    <type
    <start_time
    <stop_time
    <exit_code
    <finalized
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Row';

sub TABLE       { 'collectors' }
sub PRIMARY_KEY { 'collector_id' }
sub COLUMNS     {
    qw/collector_id runner_id name pid watched type start_time stop_time exit_code finalized/
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Collector - Row object for the C<collectors> table.

=head1 DESCRIPTION

One row per collector process: its pid, the pid it watches, its type
(C<'service'>, C<'test job'>, etc.), start/stop timestamps, the
collected process's exit code, and the timestamp the recorder
finalized its bookkeeping.

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

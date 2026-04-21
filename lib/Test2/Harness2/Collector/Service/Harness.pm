package Test2::Harness2::Collector::Service::Harness;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'Test2::Harness2::Collector::Service';

# The harness's own top-of-tree interpose collector: its ipc_parent is
# undef and its ipc_harness points at its own child (the harness
# service). End-of-life and logger-metadata sends addressed to
# ipc_harness would target that already-exiting child; overriding
# is_harness_collector to 1 makes Test2::Harness2::Collector short-
# circuit those sends instead of racing a disconnected pipe.
sub is_harness_collector { 1 }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Service::Harness - Interpose collector subclass for the harness itself.

=head1 DESCRIPTION

The harness runs its own top-of-tree interpose collector (see
L<Test2::Harness2/run_service>). That collector is unusual in two ways:

=over 4

=item *

It has no C<ipc_parent> -- there is no service above the harness to
notify.

=item *

Its C<ipc_harness> value points at its own interposed child (the
harness service). Any send addressed to C<ipc_harness> is therefore
aimed at a process that has usually already C<POSIX::_exit()>ed by
the time the collector observes EOF on its pipes.

=back

This subclass exists so call sites in
L<Test2::Harness2::Collector> can detect that situation via
C<is_harness_collector> and suppress the self-addressed sends
(C<collector_exiting> and C<collector_artifacts>) that would
otherwise fail with a disconnected-pipe warning.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut

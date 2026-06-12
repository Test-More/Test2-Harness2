package Test2::Harness2::Util::HiResTime;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes ();

use Importer Importer => 'import';

our @EXPORT_OK = qw/hi_res_time/;

# Test seam. Tests local-bind $CLOCK to a coderef returning a
# deterministic timeline; production callers never touch it. Having
# the seam live here (rather than re-declared in every resource that
# samples time) means tests only need to override one symbol to
# control time across all consumers.
our $CLOCK = \&Time::HiRes::time;

sub hi_res_time { $CLOCK->() }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::HiResTime - Sub-second wall-clock reader with a single test seam.

=head1 SYNOPSIS

    use Test2::Harness2::Util::HiResTime qw/hi_res_time/;

    my $t = hi_res_time();          # seconds since the epoch, fractional

In tests:

    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $fake_now };
    # every consumer of hi_res_time() now sees $fake_now

=head1 DESCRIPTION

Thin wrapper around L<Time::HiRes/time> that consumers call instead
of C<Time::HiRes::time> directly, so a single C<local>-bound override
in tests is enough to drive a deterministic timeline across every
caller.

=head1 EXPORTS

=over 4

=item $secs = hi_res_time()

Returns the current wall-clock time as a fractional number of
seconds since the epoch. Equivalent to calling
C<Time::HiRes::time()> unless C<$CLOCK> has been locally rebound to a
coderef (the test seam).

=back

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut

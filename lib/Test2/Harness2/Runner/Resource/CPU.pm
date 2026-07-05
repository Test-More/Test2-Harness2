package Test2::Harness2::Runner::Resource::CPU;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Object::HashBase qw{
    &Test2::Harness2::Role::Resource::Utilizer
    <settings
    <state
    <arg
    <name
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Resource::CPU - Throttle new test starts against system
CPU load.

=head1 DESCRIPTION

Defers new test starts when aggregate system CPU usage meets a threshold
(C<utilize_percent>, default 80). It does B<not> sample C</proc> itself: it reads
the shared system-load snapshot the runner's sampler service maintains, so it
works on every platform the sampler supports (Linux and the BSDs), and every
resource sees the same value.

Throttling never permanently skips a test -- when CPU is saturated C<available>
returns C<0> (wait), and a starvation floor (C<min_concurrent>, default 1) keeps
at least that many tests running even under sustained saturation.

=head1 SYNOPSIS

    yath test -R CPU             # default: defer at cpu% >= 80
    yath test -R CPU=70          # defer at cpu% >= 70
    yath test -R CPU --utilize 65

=head1 ATTRIBUTES

=over 4

=item utilize_percent

The CPU-busy percentage (0 < pct < 100) at which new starts defer. Defaults to 80.

=item min_concurrent

Starvation floor; deferral only applies once this many tests are in flight.
Defaults to 1.

=back

=cut

sub init ($self) {
    $self->{+NAME} //= 'cpu';

    # Precedence: inline -R CPU=N, then --utilize, then the default 80.
    my $inline = $self->{+ARG};
    $self->{+UTILIZE_PERCENT} //= (defined($inline) && length($inline)) ? $inline : ($self->_utilize_from_settings // 80);
    $self->{+MIN_CONCURRENT}  //= 1;

    my $u = $self->{+UTILIZE_PERCENT};
    croak "Resource::CPU: utilize_percent must be > 0 and < 100 (got '" . ($u // 'undef') . "')"
        unless defined $u && $u =~ m/^[0-9]+(?:\.[0-9]+)?\z/ && $u > 0 && $u < 100;

    return;
}

=head1 PUBLIC METHODS

The instance's configured name is available via the generated C<name> reader
(defaults to C<cpu>). The scheduler-facing contract (C<available> / C<assign> /
C<record> / C<release>) is provided by
L<Test2::Harness2::Role::Resource::Utilizer>.

=over 4

=item $bool = $self->is_temporarily_unavailable

True when the latest reported rounded CPU percentage is at or above
C<utilize_percent>.

=back

=cut

sub is_temporarily_unavailable ($self) {
    my $cpu = $self->_current_cpu_pct;
    return 0 unless defined $cpu;
    return $cpu >= $self->{+UTILIZE_PERCENT} ? 1 : 0;
}

sub status_data ($self) {
    return [
        {
            tables => [
                {
                    header => [qw/Name Utilize% CPU% InFlight/],
                    rows   => [
                        [
                            $self->{+NAME},
                            $self->{+UTILIZE_PERCENT},
                            defined($self->_current_cpu_pct) ? $self->_current_cpu_pct : '--',
                            $self->in_flight,
                        ],
                    ],
                },
            ],
        },
    ];
}

=head1 PRIVATE METHODS

=over 4

=item $pct = $self->_current_cpu_pct

The latest reported rounded CPU percentage from the runner's system-load snapshot,
or C<undef> when no snapshot has arrived yet (or the platform reports no CPU
percentage).

=back

=cut

sub _current_cpu_pct ($self) {
    my $state = $self->{+STATE}     or return undef;
    my $load  = $state->system_load or return undef;
    return $load->{cpu_pct};
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness2/>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

package Test2::Harness2::Runner::Resource::Memory;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Util::Units qw/parse_size_or_pct/;

use Object::HashBase qw{
    &Test2::Harness2::Role::Resource::Utilizer
    <settings
    <state
    <arg
    <name
    <min_free
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Resource::Memory - Throttle new test starts when free
memory is low.

=head1 DESCRIPTION

Defers new test starts when free system memory drops below a threshold. The
threshold (C<min_free>) is a percentage of total memory (default 5%) or an
absolute byte size (C<512mb>). It does B<not> sample C</proc> itself: it reads the
shared system-load snapshot the runner's sampler service maintains, so it works on
every platform the sampler reports memory for, and every resource sees the same
value.

When C<--utilize PCT> is also set, both thresholds apply and the B<more
conservative> (larger free-memory requirement) wins: the C<--utilize> percentage
contributes a free-memory floor of C<(100 - PCT)%> of total memory.

Throttling never permanently skips a test -- when memory is low C<available>
returns C<0> (wait), and a starvation floor (C<min_concurrent>, default 1) keeps
at least that many tests running even under sustained pressure.

=head1 SYNOPSIS

    yath test -R Memory          # default: defer when free < 5% of total
    yath test -R Memory=20%      # defer when free < 20% of total
    yath test -R Memory=512mb    # defer when free < 512 MiB
    yath test -R Memory --utilize 80   # the more conservative of the two wins

=head1 ATTRIBUTES

=over 4

=item min_free

The free-memory threshold, as C<< {kind => 'pct'|'bytes', value => N} >>. Defaults
to 5%.

=item min_concurrent

Starvation floor; deferral only applies once this many tests are in flight.
Defaults to 1.

=back

=cut

sub init {
    my $self = shift;

    $self->{+NAME} //= 'memory';

    # Precedence: inline -R Memory=SPEC, then --utilize floor, then the default 5%.
    my $inline = $self->{+ARG};
    if (!defined($self->{+MIN_FREE}) && defined($inline) && length($inline)) {
        my $parsed;
        my $ok  = eval { $parsed = parse_size_or_pct($inline, name => 'min_free'); 1 };
        my $err = $@;
        croak "Resource::Memory: bad threshold '$inline': $err" unless $ok;
        $self->{+MIN_FREE} = $parsed;
    }

    $self->{+MIN_FREE}       //= $self->_min_free_from_settings // {kind => 'pct', value => 5};
    $self->{+MIN_CONCURRENT} //= 1;

    my $mf = $self->{+MIN_FREE};
    croak "Resource::Memory: 'min_free' must be a {kind, value} hashref"
        unless ref($mf) eq 'HASH';
    croak "Resource::Memory: min_free.kind must be 'pct' or 'bytes'"
        unless defined $mf->{kind} && ($mf->{kind} eq 'pct' || $mf->{kind} eq 'bytes');
    croak "Resource::Memory: min_free.value must be > 0"
        unless defined $mf->{value} && $mf->{value} > 0;
    croak "Resource::Memory: min_free.value (pct) must be < 100"
        if $mf->{kind} eq 'pct' && $mf->{value} >= 100;

    return;
}

=head1 PUBLIC METHODS

The instance's configured name is available via the generated C<name> reader
(defaults to C<memory>). The scheduler-facing contract (C<available> / C<assign> /
C<record> / C<release>) is provided by
L<Test2::Harness2::Role::Resource::Utilizer>.

=over 4

=item $bool = $self->is_temporarily_unavailable

True when reported free memory is below the effective threshold (the more
conservative of C<min_free> and the C<--utilize> floor).

=back

=cut

sub is_temporarily_unavailable {
    my $self = shift;

    my ($total, $available) = $self->_current_mem;
    return 0 unless defined $total && defined $available;

    my $threshold = $self->_effective_min_free_bytes($total);
    return $available < $threshold ? 1 : 0;
}

sub status_data {
    my $self = shift;

    my ($total, $available) = $self->_current_mem;
    my $threshold = defined($total) ? $self->_effective_min_free_bytes($total) : undef;

    return [
        {
            tables => [
                {
                    header => [qw/Name MinFree FreeBytes ThresholdBytes InFlight/],
                    rows   => [
                        [
                            $self->{+NAME},
                            $self->_min_free_str,
                            $available // '--',
                            $threshold // '--',
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

=item ($total, $available) = $self->_current_mem

Total and available memory in bytes from the runner's system-load snapshot, or an
empty list when no snapshot has arrived (or the platform reports no memory).

=item $bytes = $self->_effective_min_free_bytes($total)

The free-memory threshold in bytes: the larger of C<min_free> and the C<--utilize>
floor (conservative-wins).

=item $spec = $self->_min_free_from_settings

A C<min_free> spec derived from C<--utilize> ((100 - pct)%), or C<undef> when no
C<--utilize> was given.

=item $str = $self->_min_free_str

A human-readable form of the configured C<min_free> for status output.

=back

=cut

sub _current_mem {
    my $self  = shift;
    my $state = $self->{+STATE}     or return ();
    my $load  = $state->system_load or return ();
    my $total = $load->{mem_total};
    my $avail = $load->{mem_available};
    return () unless defined $total && defined $avail;
    return ($total, $avail);
}

sub _effective_min_free_bytes {
    my $self = shift;
    my ($total) = @_;

    my $mf = $self->{+MIN_FREE};
    my $explicit_bytes =
          $mf->{kind} eq 'bytes'
        ? $mf->{value}
        : int($total * $mf->{value} / 100);

    my $utilize_bytes = 0;
    my $utilize       = $self->_utilize_from_settings;
    $utilize_bytes = int($total * (100 - $utilize) / 100) if defined $utilize;

    return $explicit_bytes > $utilize_bytes ? $explicit_bytes : $utilize_bytes;
}

sub _min_free_from_settings {
    my $self    = shift;
    my $utilize = $self->_utilize_from_settings;
    return undef unless defined $utilize;
    return {kind => 'pct', value => 100 - $utilize};
}

sub _min_free_str {
    my $self = shift;
    my $mf   = $self->{+MIN_FREE};
    return $mf->{kind} eq 'pct' ? "$mf->{value}%" : "$mf->{value}b";
}

1;

__END__

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

package Test2::Harness2::Runner::Resource::UnixLimits;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Util::Units qw/parse_count_or_pct parse_size_or_pct/;

use Object::HashBase qw{
    &Test2::Harness2::Role::Resource::Utilizer
    <settings
    <state
    <arg
    <name
    <nofile
    <as
    +supported
    +static_limits
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Resource::UnixLimits - Throttle new test starts against
per-process Unix resource limits (RLIMIT nofile / as).

=head1 DESCRIPTION

Defers new test starts when the runner's own process soft C<ulimit>s (open files
C<nofile>, address space C<as>) approach saturation. It reads its metrics
B<in-resource, runner-local> -- the static RLIMIT ceilings are read once from
C</proc/self/limits>, and the volatile/current usage (open fd count, virtual
memory size) is read fresh at availability-check time from C</proc/self/fd> and
C</proc/self/status>. It does B<not> use the shared system-load sampler snapshot
(that would count the sampler's fds and a coarse periodic snapshot races burst
spawns).

C<nofile> defaults on with 10% headroom; C<as> is off until an explicit threshold
is supplied. Thresholds accept a count (C<128>), a percentage-of-limit (C<10%>),
or (for C<as>) an absolute byte size (C<512mb>). When C<--utilize PCT> is also set
it layers on top: the effective free-headroom requirement is the B<more
conservative> of the explicit threshold and the C<--utilize>-derived floor of
C<(100 - PCT)%> of the limit.

=head2 Why there is no nproc dimension

There is deliberately no C<nproc> throttle. C<RLIMIT_NPROC> is enforced by the
kernel B<per real UID> -- at fork/clone it checks the user's total task count
(every thread is a task) against the limit, not the runner process's own thread
count. The runner-local C<Threads:> reading (constant 1) can never approach that
per-UID total, so a percentage gate could never fire and an absolute threshold
would silently throttle every run to C<min_concurrent>. A correct measure -- the
per-UID sum of C<Threads:> across all of C</proc/*/status> -- is accurate to first
order but costs a full C</proc> scan on every availability check on the scheduler
hot path (and TTL-caching it reintroduces the burst-spawn race the fresh-read
design exists to avoid). Until a cheap, correct source exists the dimension is
dropped rather than shipped as a gate that cannot fire; an explicit
C<-R UnixLimits=nproc=...> is a hard error.

Throttling never permanently skips a test -- when a dimension is near its limit
C<available> returns C<0> (a wait), and a starvation floor (C<min_concurrent>,
default 1) keeps at least that many tests running even under sustained pressure.

=head1 SUPPORTED PLATFORMS

Reads the RLIMIT metrics from Linux C</proc>. On a host without C</proc>
(macOS/BSD/Windows) the resource gracefully B<deactivates> -- it imposes no
constraint (treated as infinite) and logs a single verbose notice; it never
crashes. Off-Linux RLIMIT support would require the optional L<BSD::Resource>
module; when it is absent the resource simply stays deactivated.

=head1 SYNOPSIS

    yath test -R UnixLimits              # nofile, 10% headroom
    yath test -R UnixLimits=10%          # bare pct -> nofile
    yath test -R UnixLimits=nofile=128   # per-dimension
    yath test -R UnixLimits=as=512mb     # add an address-space gate

=head1 ATTRIBUTES

=over 4

=item nofile / as

Each is a C<< {kind => 'count'|'pct'|'bytes', value => N} >> threshold (or undef
when not configured). C<nofile> defaults to C<< {kind => 'pct', value => 10} >>;
C<as> defaults off. (There is no C<nproc> dimension -- see L</Why there is no
nproc dimension>.)

=item min_concurrent

Starvation floor; deferral only applies once this many tests are in flight.
Defaults to 1.

=back

=cut

sub init ($self) {
    $self->{+NAME} //= 'unixlimits';

    $self->_parse_inline_arg;

    # Default: nofile on with 10% headroom; as off until requested. (There is no
    # nproc dimension -- see the POD "Why there is no nproc dimension" note.)
    $self->{+NOFILE} //= {kind => 'pct', value => 10};

    for my $dim (qw/nofile/) {
        my $v = $self->{$dim};
        croak "Resource::UnixLimits: $dim must be a {kind, value} hashref"
            unless ref($v) eq 'HASH';
        croak "Resource::UnixLimits: $dim.kind must be 'count' or 'pct'"
            unless defined $v->{kind} && ($v->{kind} eq 'count' || $v->{kind} eq 'pct');
        croak "Resource::UnixLimits: $dim.value must be > 0"
            unless defined $v->{value} && $v->{value} > 0;
    }

    if (my $as = $self->{+AS}) {
        croak "Resource::UnixLimits: as.kind must be 'bytes' or 'pct'"
            unless ref($as) eq 'HASH' && defined $as->{kind} && ($as->{kind} eq 'bytes' || $as->{kind} eq 'pct');
        croak "Resource::UnixLimits: as.value must be > 0"
            unless defined $as->{value} && $as->{value} > 0;
    }

    $self->{+MIN_CONCURRENT} //= 1;

    return;
}

# Parse the inline '-R UnixLimits=ARG' string. ARG is a comma-separated list of
# 'nofile=SPEC' / 'as=SPEC', or a bare 'N%' which applies to nofile. An explicit
# 'nproc=SPEC' is a hard error: the nproc dimension was removed because
# RLIMIT_NPROC cannot be measured cheaply or correctly from the runner process
# (see the POD "Why there is no nproc dimension").
sub _parse_inline_arg ($self) {
    my $arg = $self->{+ARG};
    return unless defined $arg && length $arg;

    for my $entry (split /,/, $arg) {
        $entry =~ s/^\s+//;
        $entry =~ s/\s+$//;
        next unless length $entry;

        if ($entry =~ m/^nproc=/) {
            # Never silently ignore explicit config -- that is the
            # gate-that-cannot-fire defect in a new costume.
            croak "Resource::UnixLimits: the nproc dimension is disabled: "
                . "RLIMIT_NPROC is enforced per real UID (the user's total task "
                . "count), which cannot be measured cheaply or correctly from the "
                . "runner process; remove 'nproc=...' (nofile and as remain supported)";
        }
        elsif ($entry =~ m/^nofile=(.+)\z/) {
            my $raw = $1;
            my $parsed;
            my $ok  = eval { $parsed = parse_count_or_pct($raw, name => 'nofile'); 1 };
            my $err = $@;
            croak "Resource::UnixLimits: bad nofile in '$entry': $err" unless $ok;
            $self->{+NOFILE} = $parsed;
        }
        elsif ($entry =~ m/^as=(.+)\z/) {
            my $raw = $1;
            my $parsed;
            my $ok  = eval { $parsed = parse_size_or_pct($raw, name => 'as'); 1 };
            my $err = $@;
            croak "Resource::UnixLimits: bad as in '$entry': $err" unless $ok;
            $self->{+AS} = $parsed;
        }
        elsif ($entry =~ m/^([0-9]+(?:\.[0-9]+)?)%\z/) {
            my $pct = $1;
            croak "Resource::UnixLimits: pct must be > 0 and < 100 (got '$pct')"
                unless $pct > 0 && $pct < 100;
            $self->{+NOFILE} = {kind => 'pct', value => $pct + 0};
        }
        else {
            croak "Resource::UnixLimits: unrecognised inline entry '$entry' "
                . "(expected nofile=SPEC, as=SPEC, or N%)";
        }
    }

    return;
}

=head1 PUBLIC METHODS

The instance's configured name is available via the generated C<name> reader
(defaults to C<unixlimits>). The scheduler-facing contract (C<available> /
C<assign> / C<record> / C<release>) is provided by
L<Test2::Harness2::Role::Resource::Utilizer>; C<is_supported> below is the
overridable gate that role's C<available> consults.

=over 4

=item $bool = $self->is_supported

True when the RLIMIT metrics can be read (Linux C</proc>). Cached. On an
unsupported host this emits a single verbose notice and returns false; the
resource then imposes no constraint.

=item $bool = $self->is_temporarily_unavailable

True when any configured dimension is within its effective headroom of the soft
limit. Always false on an unsupported platform.

=back

=cut

sub is_supported ($self) {
    return $self->{+SUPPORTED} if defined $self->{+SUPPORTED};

    if ($^O eq 'linux' && -r '/proc/self/limits' && -r '/proc/self/status' && -d '/proc/self/fd') {
        return $self->{+SUPPORTED} = 1;
    }

    # Off-Linux RLIMIT support would require BSD::Resource (optional). We do not
    # implement that path yet; deactivate gracefully with a single verbose notice.
    my $extra = '';
    unless ($^O eq 'linux') {
        my $have_bsd = eval { require BSD::Resource; 1 } ? 1 : 0;
        $extra = $have_bsd
            ? " (BSD::Resource is installed but off-Linux RLIMIT throttling is not implemented)"
            : " (install BSD::Resource for off-Linux support; not yet wired up)";
    }

    $self->_verbose_log(
        "Resource::UnixLimits is unsupported on this platform ($^O): /proc RLIMIT "
        . "metrics are unavailable; deactivating (no throttling)$extra"
    );

    return $self->{+SUPPORTED} = 0;
}

sub is_temporarily_unavailable ($self) {
    return 0 unless $self->is_supported;

    my $dims = $self->_dimension_states;
    for my $d (values %$dims) {
        return 1 if $d->{state} eq 'low';
    }
    return 0;
}

sub status_data ($self) {
    unless ($self->is_supported) {
        return [
            {
                tables => [
                    {
                        header => [qw/Name State InFlight/],
                        rows   => [[$self->{+NAME}, 'unsupported', $self->in_flight]],
                    },
                ],
            },
        ];
    }

    my $dims = $self->_dimension_states;

    my @rows;
    for my $dim (qw/nofile as/) {
        my $d = $dims->{$dim} or next;
        push @rows => [
            $dim,
            $d->{state},
            $d->{soft_cap}           // 'unlimited',
            $d->{current}            // '--',
            $d->{free}               // '--',
            $d->{effective_min_free} // '--',
        ];
    }

    return [
        {
            tables => [
                {
                    header => [qw/Dimension State SoftCap Current Free MinFree/],
                    rows   => \@rows,
                    title  => "$self->{+NAME} (in flight: " . $self->in_flight . ")",
                },
            ],
        },
    ];
}

=head1 PRIVATE METHODS

=over 4

=item $self->_verbose_log($msg)

Emit C<$msg> to STDERR once (deduped). Used for the unsupported-platform notice.

=item $limits = $self->_read_self_limits

Static RLIMIT soft caps from C</proc/self/limits>, read once and cached. Returns
C<< {nofile, as} >> (each a number or undef for 'unlimited').

=item $status = $self->_read_self_status

Volatile C</proc/self/status> field C<< {VmSize} >> (VmSize in kB, used for the
C<as> dimension), read fresh each call.

=item $n = $self->_count_self_fd

Current open-fd count from C</proc/self/fd>, read fresh each call.

=item %info = $self->_assess_dimension($dim, $soft_cap, $current)

Compute the state (ok/low) for one dimension against its threshold and the
optional C<--utilize> floor.

=item $dims = $self->_dimension_states

Sample + assess every configured dimension. The C<as> key is absent unless an
C<as> threshold is configured.

=back

=cut

my %WARNED;
sub _verbose_log ($self, $msg) {
    return if $WARNED{$msg}++;
    warn "$msg\n";
    return;
}

sub _read_self_limits ($self) {
    return $self->{+STATIC_LIMITS} if $self->{+STATIC_LIMITS};

    my %out;
    open my $fh, '<', '/proc/self/limits' or return $self->{+STATIC_LIMITS} = {};
    while (my $line = <$fh>) {
        if ($line =~ m/^Max open files\s+(\S+)/) {
            $out{nofile} = $1 eq 'unlimited' ? undef : $1 + 0;
        }
        elsif ($line =~ m/^Max address space\s+(\S+)/) {
            $out{as} = $1 eq 'unlimited' ? undef : $1 + 0;
        }
    }
    close $fh;

    return $self->{+STATIC_LIMITS} = \%out;
}

sub _read_self_status ($self) {
    my %out;
    open my $fh, '<', '/proc/self/status' or return \%out;
    while (my $line = <$fh>) {
        $out{VmSize} = $1 + 0 if $line =~ m/^VmSize:\s+([0-9]+)\s*kB/;
    }
    close $fh;
    return \%out;
}

sub _count_self_fd ($self) {
    opendir my $dh, '/proc/self/fd' or return 0;
    my $n = 0;
    while (my $e = readdir $dh) {
        next if $e eq '.' || $e eq '..';
        $n++;
    }
    closedir $dh;
    return $n;
}

sub _assess_dimension ($self, $dim, $soft_cap, $current) {
    my $headroom = $self->{$dim};

    # No threshold configured for this dimension, or the soft cap is unlimited:
    # always ok (no constraint).
    return (state => 'ok', soft_cap => $soft_cap, current => $current, effective_min_free => 0, headroom => $headroom)
        unless defined $headroom && defined $soft_cap;

    my $explicit =
          $headroom->{kind} eq 'count' ? $headroom->{value}
        : $headroom->{kind} eq 'bytes' ? $headroom->{value}
        :                                int($soft_cap * $headroom->{value} / 100);

    my $utilize_floor = 0;
    if (defined(my $utilize = $self->_utilize_from_settings)) {
        $utilize_floor = int($soft_cap * (100 - $utilize) / 100);
    }

    my $effective = $explicit > $utilize_floor ? $explicit : $utilize_floor;
    my $free      = $soft_cap - $current;
    my $state     = $free < $effective ? 'low' : 'ok';

    return (
        state              => $state,
        soft_cap           => $soft_cap,
        current            => $current,
        free               => $free,
        effective_min_free => $effective,
        headroom           => $headroom,
    );
}

sub _dimension_states ($self) {
    my $limits  = $self->_read_self_limits;
    my $status  = $self->_read_self_status;
    my $fdcount = $self->_count_self_fd;

    my %dims;
    $dims{nofile} = {$self->_assess_dimension('nofile', $limits->{nofile}, $fdcount)};

    if ($self->{+AS}) {
        my $vmsize_bytes = ($status->{VmSize} // 0) * 1024;
        $dims{as} = {$self->_assess_dimension('as', $limits->{as}, $vmsize_bytes)};
    }

    return \%dims;
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

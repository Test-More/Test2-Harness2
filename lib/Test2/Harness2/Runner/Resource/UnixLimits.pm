package Test2::Harness2::Runner::Resource::UnixLimits;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Units qw/parse_count_or_pct parse_size_or_pct/;

# Predeclare new() so HashBase does not generate one (we define our own below).
sub new;

use Object::HashBase qw{
    &Test2::Harness2::Runner::Resource
    &Test2::Harness2::Role::Resource::Utilizer
    <settings
    <state
    <arg
    <name
    <nproc
    <nofile
    <as
    +supported
    +static_limits
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Resource::UnixLimits - Throttle new test starts against
per-process Unix resource limits (RLIMIT nproc / nofile / as).

=head1 DESCRIPTION

Defers new test starts when the runner's own process soft C<ulimit>s (number of
processes/threads C<nproc>, open files C<nofile>, address space C<as>) approach
saturation. It reads its metrics B<in-resource, runner-local> -- the static
RLIMIT ceilings are read once from C</proc/self/limits>, and the volatile/current
usage (thread count, open fd count, virtual memory size) is read fresh at
availability-check time from C</proc/self/status> and C</proc/self/fd>. It does
B<not> use the shared system-load sampler snapshot (that would count the
sampler's fds and a coarse periodic snapshot races burst spawns).

C<nproc> and C<nofile> default on with 10% headroom; C<as> is off until an
explicit threshold is supplied. Thresholds accept a count (C<128>), a
percentage-of-limit (C<10%>), or (for C<as>) an absolute byte size (C<512mb>).
When C<--utilize PCT> is also set it layers on top: the effective free-headroom
requirement is the B<more conservative> of the explicit threshold and the
C<--utilize>-derived floor of C<(100 - PCT)%> of the limit.

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

    yath test -R UnixLimits                       # nproc + nofile, 10% headroom
    yath test -R UnixLimits=10%                   # bare pct -> nproc + nofile
    yath test -R UnixLimits=nproc=128,nofile=10%  # per-dimension
    yath test -R UnixLimits=as=512mb              # add an address-space gate

=head1 ATTRIBUTES

=over 4

=item nproc / nofile / as

Each is a C<< {kind => 'count'|'pct'|'bytes', value => N} >> threshold (or undef
when not configured). C<nproc>/C<nofile> default to C<< {kind => 'pct', value =>
10} >>; C<as> defaults off.

=item min_concurrent

Starvation floor; deferral only applies once this many tests are in flight.
Defaults to 1.

=back

=cut

sub new {
    my $class = shift;
    my $self  = bless {@_}, $class;
    $self->init();
    return $self;
}

sub init {
    my $self = shift;

    $self->{+NAME} //= 'unixlimits';

    $self->_parse_inline_arg;

    # Defaults: nproc + nofile on with 10% headroom; as off until requested.
    $self->{+NPROC}  //= {kind => 'pct', value => 10};
    $self->{+NOFILE} //= {kind => 'pct', value => 10};

    for my $dim (qw/nproc nofile/) {
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
# 'nproc=SPEC' / 'nofile=SPEC' / 'as=SPEC', or a bare 'N%' which applies to both
# nproc and nofile (matches old3 semantics).
sub _parse_inline_arg {
    my $self = shift;

    my $arg = $self->{+ARG};
    return unless defined $arg && length $arg;

    for my $entry (split /,/, $arg) {
        $entry =~ s/^\s+//;
        $entry =~ s/\s+$//;
        next unless length $entry;

        if ($entry =~ m/^(nproc|nofile)=(.+)\z/) {
            my ($dim, $raw) = ($1, $2);
            my $parsed;
            my $ok  = eval { $parsed = parse_count_or_pct($raw, name => $dim); 1 };
            my $err = $@;
            croak "Resource::UnixLimits: bad $dim in '$entry': $err" unless $ok;
            $self->{$dim} = $parsed;
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
            $self->{+NPROC}  = {kind => 'pct', value => $pct + 0};
            $self->{+NOFILE} = {kind => 'pct', value => $pct + 0};
        }
        else {
            croak "Resource::UnixLimits: unrecognised inline entry '$entry' "
                . "(expected nproc=SPEC, nofile=SPEC, as=SPEC, or N%)";
        }
    }

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $name = $self->resource_name

The instance's configured name (defaults to C<unixlimits>).

=item $bool = $self->is_supported

True when the RLIMIT metrics can be read (Linux C</proc>). Cached. On an
unsupported host this emits a single verbose notice and returns false; the
resource then imposes no constraint.

=item $val = $self->available(\%task)

C<1> when there is headroom (or the platform is unsupported / floor not met),
C<0> to defer when a dimension is near its limit and the floor is met.

=item $self->assign(\%task, \%state)

Records the job so the in-flight count tracks it; assigns no env/args and emits
no record payload that mutates shared state.

=item $bool = $self->is_temporarily_unavailable

True when any configured dimension is within its effective headroom of the soft
limit. Always false on an unsupported platform.

=back

=cut

sub resource_name { my $self = shift; return $self->{+NAME} }

sub is_supported {
    my $self = shift;

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

sub available {
    my $self = shift;
    my ($task) = @_;
    croak "'job' is required" unless defined $task;

    return 1 unless $self->is_supported;
    return $self->should_defer_for_utilization ? 0 : 1;
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;
    $state->{record} = {job_id => $task->{job_id}, stamp => time};
    return;
}

sub record {
    my $self = shift;
    my ($job_id, $info) = @_;
    $self->track_started($job_id);
    return;
}

sub release {
    my $self = shift;
    my ($job_id) = @_;
    $self->track_released($job_id);
    return;
}

sub is_temporarily_unavailable {
    my $self = shift;

    return 0 unless $self->is_supported;

    my $dims = $self->_dimension_states;
    for my $d (values %$dims) {
        return 1 if $d->{state} eq 'low';
    }
    return 0;
}

sub status_data {
    my $self = shift;

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
    for my $dim (qw/nproc nofile as/) {
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
C<< {nproc, nofile, as} >> (each a number or undef for 'unlimited').

=item $status = $self->_read_self_status

Volatile C</proc/self/status> fields C<< {Threads, VmSize} >> (VmSize in kB),
read fresh each call.

=item $n = $self->_count_self_fd

Current open-fd count from C</proc/self/fd>, read fresh each call.

=item %info = $self->_assess_dimension($dim, $soft_cap, $current)

Compute the state (ok/low) for one dimension against its threshold and the
optional C<--utilize> floor.

=item $dims = $self->_dimension_states

Sample + assess every configured dimension. The C<as> key is absent unless an
C<as> threshold is configured.

=item $pct = $self->_utilize_from_settings

The C<--utilize> percentage from settings, or undef.

=back

=cut

my %WARNED;
sub _verbose_log {
    my $self = shift;
    my ($msg) = @_;
    return if $WARNED{$msg}++;
    warn "$msg\n";
    return;
}

sub _read_self_limits {
    my $self = shift;

    return $self->{+STATIC_LIMITS} if $self->{+STATIC_LIMITS};

    my %out;
    open my $fh, '<', '/proc/self/limits' or return $self->{+STATIC_LIMITS} = {};
    while (my $line = <$fh>) {
        if ($line =~ m/^Max processes\s+(\S+)/) {
            $out{nproc} = $1 eq 'unlimited' ? undef : $1 + 0;
        }
        elsif ($line =~ m/^Max open files\s+(\S+)/) {
            $out{nofile} = $1 eq 'unlimited' ? undef : $1 + 0;
        }
        elsif ($line =~ m/^Max address space\s+(\S+)/) {
            $out{as} = $1 eq 'unlimited' ? undef : $1 + 0;
        }
    }
    close $fh;

    return $self->{+STATIC_LIMITS} = \%out;
}

sub _read_self_status {
    my $self = shift;

    my %out;
    open my $fh, '<', '/proc/self/status' or return \%out;
    while (my $line = <$fh>) {
        $out{Threads} = $1 + 0 if $line =~ m/^Threads:\s+([0-9]+)/;
        $out{VmSize}  = $1 + 0 if $line =~ m/^VmSize:\s+([0-9]+)\s*kB/;
    }
    close $fh;
    return \%out;
}

sub _count_self_fd {
    my $self = shift;

    opendir my $dh, '/proc/self/fd' or return 0;
    my $n = 0;
    while (my $e = readdir $dh) {
        next if $e eq '.' || $e eq '..';
        $n++;
    }
    closedir $dh;
    return $n;
}

sub _assess_dimension {
    my $self = shift;
    my ($dim, $soft_cap, $current) = @_;

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

sub _dimension_states {
    my $self = shift;

    my $limits  = $self->_read_self_limits;
    my $status  = $self->_read_self_status;
    my $fdcount = $self->_count_self_fd;

    my %dims;
    $dims{nproc}  = {$self->_assess_dimension('nproc',  $limits->{nproc},  $status->{Threads} // 0)};
    $dims{nofile} = {$self->_assess_dimension('nofile', $limits->{nofile}, $fdcount)};

    if ($self->{+AS}) {
        my $vmsize_bytes = ($status->{VmSize} // 0) * 1024;
        $dims{as} = {$self->_assess_dimension('as', $limits->{as}, $vmsize_bytes)};
    }

    return \%dims;
}

sub _utilize_from_settings {
    my $self     = shift;
    my $settings = $self->{+SETTINGS} or return undef;
    return undef unless $settings->check_group('runner');
    my $runner = $settings->runner;
    return undef unless $runner->check_option('utilize');
    return $runner->utilize;
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

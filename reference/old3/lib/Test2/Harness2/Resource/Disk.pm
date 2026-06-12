package Test2::Harness2::Resource::Disk;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Harness2::Util::Units qw/parse_size_or_pct/;
use Test2::Harness2::Util::HiResTime qw/hi_res_time/;

use Object::HashBase qw{
    <mounts
    <samples
    &Test2::Harness2::Role::Resource
};

# Known keys; other resource-group settings are ignored.
my %OPTION_KEYS = map { $_ => 1 } qw/mounts/;

sub init {
    my $self = shift;

    $self->{+MOUNTS}  //= {};
    $self->{+SAMPLES} //= {};

    croak "Resource::Disk: 'mounts' is required and must be non-empty"
        unless ref($self->{+MOUNTS}) eq 'HASH' && keys %{$self->{+MOUNTS}};

    # Defer Filesys::Df load: optional dep, option-loader require()s every Resource class.
    my $loaded = eval { require Filesys::Df; 1 };
    my $err    = $@;
    unless ($loaded) {
        # Warn on broken-install / XS errors so they don't get masked by the install hint below.
        warn $err if $err && $err !~ m{\bCan't locate Filesys/Df\.pm\b};
        croak "Resource::Disk requires Filesys::Df; install it (cpanm Filesys::Df) and retry";
    }

    for my $mp (sort keys %{$self->{+MOUNTS}}) {
        croak "Resource::Disk: mount '$mp' does not exist" unless -e $mp;
        my $sample;
        eval { $sample = Filesys::Df::df($mp, 1); 1 }
            or croak "Resource::Disk: mount '$mp' could not be sampled: $@";
        croak "Resource::Disk: mount '$mp' returned no sample"
            unless ref($sample) eq 'HASH' && defined $sample->{bavail};
    }
}

sub _evaluate_threshold {
    my ($threshold, $free_bytes, $total_bytes) = @_;

    croak "evaluate_threshold requires a parsed threshold hashref"
        unless ref($threshold) eq 'HASH'
        && defined $threshold->{kind}
        && defined $threshold->{value};

    croak "evaluate_threshold requires non-negative free_bytes"
        unless defined $free_bytes && $free_bytes >= 0;

    if ($threshold->{kind} eq 'pct') {
        croak "evaluate_threshold requires positive total_bytes for pct threshold"
            unless defined $total_bytes && $total_bytes > 0;
        my $free_pct = ($free_bytes / $total_bytes) * 100;
        return $free_pct >= $threshold->{value} ? 'ok' : 'low';
    }

    return $free_bytes >= $threshold->{value} ? 'ok' : 'low'
        if $threshold->{kind} eq 'bytes';

    croak "evaluate_threshold: unknown threshold kind '$threshold->{kind}'";
}

# Disk override: positional /path:THR + @file entries are not unknown kv.
sub is_unknown_kv_arg {
    my ($class, $arg, $has_next) = @_;
    return 0 unless $has_next;
    return 0 unless defined $arg;
    return 0 if ref $arg;
    return 0 if exists $OPTION_KEYS{$arg};
    return 0 if $arg =~ m{^/};
    return 0 if $arg =~ m{^@};
    return 1;
}

sub parse_options {
    my ($class, @args) = @_;

    my %out;
    my %file_mounts;
    my %inline_mounts;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        if (defined $arg && !ref($arg) && exists $OPTION_KEYS{$arg} && $i + 1 < @args) {
            $out{$arg} = $args[$i + 1];
            $i += 2;
            next;
        }

        if ($class->is_unknown_kv_arg($arg, $i + 1 < @args)) {
            $i += 2;
            next;
        }

        croak "Resource::Disk: undef positional entry" unless defined $arg;

        if (ref($arg)) {
            $i += 1;
            next;
        }

        if ($arg =~ m{^\@(.+)\z}) {
            my $path   = $1;
            my $mounts = $class->_load_config_file($path);
            $file_mounts{$_} = $mounts->{$_} for keys %$mounts;
        }
        elsif ($arg =~ m{^(/.+?):(.+)\z}) {
            my ($path, $threshold) = ($1, $2);
            my $parsed;
            eval { $parsed = parse_size_or_pct($threshold, default_unit => '%', name => 'threshold'); 1 }
                or croak "Resource::Disk: bad threshold in entry '$arg': $@";
            $inline_mounts{$path} = {min_free => $parsed};
        }
        else {
            croak "Resource::Disk: unrecognised entry '$arg' " . "(expected /path:THRESHOLD or \@/path/to/config.json)";
        }

        $i += 1;
    }

    # File values lose to inline; later inline overrides earlier file.
    my %mounts;
    $mounts{$_} = $file_mounts{$_}   for keys %file_mounts;
    $mounts{$_} = $inline_mounts{$_} for keys %inline_mounts;

    $out{mounts} = \%mounts if %mounts;

    return %out;
}

sub _load_config_file {
    my ($class, $path) = @_;

    my $data = $class->slurp_json_config($path);
    $class->whitelist_keys($data, [qw/mounts/], $path);

    my $raw_mounts = $data->{mounts} // {};
    croak "Resource::Disk: mounts in '$path' must be a JSON object"
        unless ref($raw_mounts) eq 'HASH';

    my %mounts;
    my %mount_allowed = (min_free => 1);
    for my $mp (sort keys %$raw_mounts) {
        my $cfg = $raw_mounts->{$mp};
        croak "Resource::Disk: mount '$mp' in '$path' must be a JSON object"
            unless ref($cfg) eq 'HASH';
        for my $k (sort keys %$cfg) {
            croak "Resource::Disk: unknown mount key '$k' for '$mp' in '$path'"
                unless $mount_allowed{$k};
        }
        croak "Resource::Disk: mount '$mp' in '$path' missing 'min_free'"
            unless defined $cfg->{min_free};
        my $threshold;
        my $ok = eval {
            $threshold = parse_size_or_pct($cfg->{min_free}, default_unit => '%', name => 'threshold');
            1;
        };
        my $err = $@;
        croak "Resource::Disk: bad threshold for mount '$mp' in '$path': $err" unless $ok;
        $mounts{$mp} = {min_free => $threshold};
    }

    return \%mounts;
}

sub available {
    my ($self, %p) = @_;

    croak "'job' is required" unless defined $p{job};

    # Sample every mount so status() reflects fresh readings for all of them.
    $self->_take_sample($_) for keys %{$self->{+MOUNTS}};

    for my $mp (keys %{$self->{+MOUNTS}}) {
        my $sample = $self->{+SAMPLES}->{$mp};
        return 0 if !$sample || ($sample->{state} // 'unknown') ne 'ok';
    }

    return 1;
}

# 3 consecutive sample failures => permanent_broken.
sub _take_sample {
    my ($self, $mp) = @_;

    my $now   = hi_res_time();
    my $cache = $self->{+SAMPLES}->{$mp};

    # block_size=1: Filesys::Df returns bavail/blocks in bytes, not blocks.
    my $sample;
    my $ok  = eval { $sample = Filesys::Df::df($mp, 1); 1 };
    my $err = $@;

    if (!$ok || !$sample || ref($sample) ne 'HASH' || !defined $sample->{bavail}) {
        my $fails = ($cache->{consecutive_failures} // 0) + 1;
        $self->{+SAMPLES}->{$mp} = {
            ts                   => $now,
            free_bytes           => $cache ? $cache->{free_bytes}  : undef,
            total_bytes          => $cache ? $cache->{total_bytes} : undef,
            used_pct             => undef,
            state                => 'unknown',
            consecutive_failures => $fails,
            last_error           => $err || 'sample returned no data',
        };
        $self->mark_permanent_broken if $fails >= 3;
        return $self->{+SAMPLES}->{$mp};
    }

    my $free  = $sample->{bavail};
    my $total = $sample->{blocks};

    my $threshold = $self->{+MOUNTS}->{$mp}->{min_free};
    my $state     = _evaluate_threshold($threshold, $free, $total);

    $self->{+SAMPLES}->{$mp} = {
        ts                   => $now,
        free_bytes           => $free,
        total_bytes          => $total,
        used_pct             => $total ? (($total - $free) / $total) * 100 : undef,
        state                => $state,
        consecutive_failures => 0,
        last_error           => undef,
    };

    return $self->{+SAMPLES}->{$mp};
}

sub status {
    my $self = shift;

    my $now = hi_res_time();

    my %mounts;
    for my $mp (sort keys %{$self->{+MOUNTS}}) {
        my $threshold = $self->{+MOUNTS}->{$mp}->{min_free};
        my $cache     = $self->{+SAMPLES}->{$mp} // {};
        $mounts{$mp} = {
            free_bytes           => $cache->{free_bytes},
            total_bytes          => $cache->{total_bytes},
            used_pct             => $cache->{used_pct},
            threshold            => $threshold,
            state                => $cache->{state} // 'unknown',
            sample_age           => defined($cache->{ts}) ? ($now - $cache->{ts}) : undef,
            consecutive_failures => $cache->{consecutive_failures} // 0,
        };
    }

    return {
        resource  => $self->resource_name,
        broken    => $self->is_broken,
        permanent => $self->is_permanent_broken,
        paused    => $self->is_paused,
        mounts    => \%mounts,
        in_flight => $self->in_flight,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::Disk - Throttle jobs when disk space is low.

=head1 SYNOPSIS

    yath -D test -R Disk=/tmp:25%
    yath -D test -R Disk=/tmp:25%,/var:1gb
    yath -D test -R Disk=@/etc/yath/disk.json
    yath -D test -R Disk=/tmp:25%,@/etc/yath/disk.json,/scratch:512mb

=head1 DESCRIPTION

Gates new test launches when free space on any tracked mount drops
below a per-mount threshold. Every C<available()> call performs a
fresh L<Filesys::Df> sample on each tracked mount — there is no
TTL cache.

This resource is a I<gate>, not a slot pool: every job is either
allowed or deferred based on whichever monitored mount is currently
lowest. C<assign> / C<release> exist only to satisfy the resource
contract; no bytes are reserved per assignment. C<status> reports
the scheduler's aggregate in-flight count alongside the per-mount
samples.

=head1 CLI

C<-R Disk=ENTRY,ENTRY,...> where ENTRY is either C</path:THRESHOLD>
or C<@/path/to/file.json>. Later entries override earlier ones
per-mount; inline always wins over file. The JSON shape:

    { "mounts": { "/tmp": { "min_free": "25%" } } }

Thresholds use the L<Test2::Harness2::Util::Units> grammar:
percentage (C<25%>) or absolute byte size (C<512mb>, C<1gb>).
Default unit when no suffix is given is C<%>.

=head1 OPTIONAL DEPENDENCY

Requires L<Filesys::Df> (not a hard dependency of this distribution).
Install when using this resource: C<cpanm Filesys::Df>.

=head1 NETWORK FILESYSTEMS

Do not use this resource on network filesystems (NFS, CIFS, sshfs,
fuse-based remote mounts). Each C<available()> call performs
C<statvfs(2)> per tracked mount, which on a network mount blocks on
a round-trip and may return stale data cached by the client. Gate
against a local scratch volume instead.

=head1 ATTRIBUTES

=over 4

=item mounts (required)

Non-empty hashref C<< { '/path' => { min_free => THRESHOLD } } >>.
THRESHOLD is a parsed hashref from
L<Test2::Harness2::Util::Units/parse_size_or_pct>.

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

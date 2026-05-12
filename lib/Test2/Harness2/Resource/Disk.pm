package Test2::Harness2::Resource::Disk;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Harness2::Util::Units qw/parse_size_or_pct/;
use Test2::Harness2::Util::HiResTime qw/hi_res_time/;
use Test2::Harness2::Util::ResourceConfig qw/slurp_json_config whitelist_keys/;

use Object::HashBase qw{
    <mounts
    <samples
    +broken
    +permanent
    &Test2::Harness2::Role::Resource
};

# Keys this resource accepts at construction time. Anything else
# (slots, job_slots, classes, utilize, no_resource, ...) is noise
# from the resource group settings hash being passed through verbatim
# by App::Yath2::Command::start::resources -- silently dropped.
my %OPTION_KEYS = map { $_ => 1 } qw/mounts/;

sub is_broken             { $_[0]->{+BROKEN} || $_[0]->{+PERMANENT} ? 1 : 0 }
sub is_permanent_broken   { $_[0]->{+PERMANENT}                     ? 1 : 0 }
sub mark_broken           { $_[0]->{+BROKEN} = 1 }
sub mark_permanent_broken { $_[0]->{+BROKEN} = $_[0]->{+PERMANENT} = 1 }

sub init {
    my $self = shift;

    $self->{+MOUNTS}      //= {};
    $self->{+ASSIGNMENTS} //= {};
    $self->{+SAMPLES}     //= {};

    croak "Resource::Disk: 'mounts' is required and must be non-empty"
        unless ref($self->{+MOUNTS}) eq 'HASH' && keys %{$self->{+MOUNTS}};

    # Defer Filesys::Df load until init so the option-loader (which
    # require()s every Resource class to discover its options) does
    # not blow up when this optional dep is missing.
    my $loaded = eval { require Filesys::Df; 1 };
    my $err    = $@;
    unless ($loaded) {
        # "Module not installed" is the expected failure mode. Anything
        # else (broken install, XS load error, syntax error in a local
        # copy, ...) is worth warning about so it does not get masked
        # by the friendly install-it message below.
        warn $err if $err && $err !~ m{\bCan't locate Filesys/Df\.pm\b};
        croak "Resource::Disk requires Filesys::Df; install it (cpanm Filesys::Df) and retry";
    }

    # Validate every configured mount: must exist and statvfs cleanly
    # right now. A typo in the mount path is a configuration error,
    # not a runtime defer.
    for my $mp (sort keys %{$self->{+MOUNTS}}) {
        croak "Resource::Disk: mount '$mp' does not exist" unless -e $mp;
        my $sample;
        eval { $sample = Filesys::Df::df($mp, 1); 1 }
            or croak "Resource::Disk: mount '$mp' could not be sampled: $@";
        croak "Resource::Disk: mount '$mp' returned no sample"
            unless ref($sample) eq 'HASH' && defined $sample->{bavail};
    }
}

# Clears transient broken/paused but leaves permanent_broken intact.
# Overrides the role's mark_resumed because Disk's broken flag and
# permanent flag are separate.
sub mark_resumed {
    my $self = shift;
    $self->{+PAUSED} = 0;
    $self->{+BROKEN} = 0 unless $self->{+PERMANENT};
}

# Compare a parsed threshold (kind => 'pct'|'bytes', value => N)
# against a sample. Returns 'ok' when free space meets or exceeds the
# threshold, 'low' otherwise.
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

# Predicate for the "drop unknown k=v pair from resource group
# settings" guard at the top of parse_options. Returns true when the
# arg looks like an unknown key paired with a following value -- the
# loop then advances past both. Anything else (positional /path:THR
# entries, @file entries, refs) is left to the per-form branches
# below. Extracting this lets parse_options stay free of multi-line
# conditional expressions in the middle of its loop.
sub _is_unknown_kv_arg {
    my ($class, $arg, $has_next) = @_;
    return 0 unless $has_next;
    return 0 unless defined $arg;
    return 0 if ref $arg;
    return 0 if exists $OPTION_KEYS{$arg};
    return 0 if $arg =~ m{^/};
    return 0 if $arg =~ m{^@};
    return 1;
}

# Class method called by App::Yath2::Command::test::_build_resources
# and App::Yath2::Command::start::resources. Translates the raw arg
# list (positional inline entries + arbitrary k=>v from the resource
# group settings) into a key/value list ready for Disk->new.
sub parse_options {
    my ($class, @args) = @_;

    my %out;
    my %file_mounts;
    my %inline_mounts;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        # Known k=>v pair: consume both.
        if (defined $arg && !ref($arg) && exists $OPTION_KEYS{$arg} && $i + 1 < @args) {
            $out{$arg} = $args[$i + 1];
            $i += 2;
            next;
        }

        # Drop unknown k=>v pairs from the resource-group settings.
        if ($class->_is_unknown_kv_arg($arg, $i + 1 < @args)) {
            $i += 2;
            next;
        }

        croak "Resource::Disk: undef positional entry" unless defined $arg;

        # Skip ref values that appear as stray v in unknown k=>v pairs
        # that were already consumed -- this shouldn't occur in normal
        # use, but guard against it.
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

    # Merge: file values lose to inline values (later inline overrides earlier file).
    my %mounts;
    $mounts{$_} = $file_mounts{$_}   for keys %file_mounts;
    $mounts{$_} = $inline_mounts{$_} for keys %inline_mounts;

    $out{mounts} = \%mounts if %mounts;

    return %out;
}

sub _load_config_file {
    my ($class, $path) = @_;

    my $data = slurp_json_config($path, 'Resource::Disk');
    whitelist_keys($data, [qw/mounts/], $path, 'Resource::Disk');

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

    # Sample every mount on every call so status() sees fresh readings
    # regardless of which mount is the first to fail.
    $self->_take_sample($_) for keys %{$self->{+MOUNTS}};

    for my $mp (keys %{$self->{+MOUNTS}}) {
        my $sample = $self->{+SAMPLES}->{$mp};
        return 0 if !$sample || ($sample->{state} // 'unknown') ne 'ok';
    }

    return 1;
}

# Sample one mount via Filesys::Df. On failure increment
# consecutive_failures; at >= 3 flip the resource to permanent_broken.
sub _take_sample {
    my ($self, $mp) = @_;

    my $now   = hi_res_time();
    my $cache = $self->{+SAMPLES}->{$mp};

    # Pass block_size = 1 so Filesys::Df returns counts in bytes
    # directly. Avoids any ambiguity about whether bavail / blocks /
    # user_bavail / user_blocks are blocks or bytes.
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

    my @assignments;
    for my $id (sort keys %{$self->{+ASSIGNMENTS}}) {
        my $a  = $self->{+ASSIGNMENTS}->{$id};
        my $tf = $a->{job}->test_file;
        push @assignments => {
            id          => $id,
            test        => $tf->relative,
            assigned_at => $a->{assigned_at},
            age         => $now - $a->{assigned_at},
        };
    }

    return {
        resource    => $self->resource_name,
        broken      => $self->is_broken,
        permanent   => $self->is_permanent_broken,
        paused      => $self->is_paused,
        mounts      => \%mounts,
        assignments => \@assignments,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::Disk - Throttle jobs when disk space is low.

=head1 SYNOPSIS

    yath -D test -j16 -R Disk=/tmp:25%
    yath -D test -j16 -R Disk=/tmp:25%,/var:1gb
    yath -D test -j16 -R Disk=@/etc/yath/disk.json
    yath -D test -j16 -R Disk=/tmp:25%,@/etc/yath/disk.json,/scratch:512mb

=head1 DESCRIPTION

Gates new test launches when free space on any tracked mount drops
below a per-mount threshold. Every C<available()> call performs a
fresh L<Filesys::Df> sample on each tracked mount — there is no
TTL cache.

This resource is a I<gate>, not a slot pool: every job is either
allowed or deferred based on whichever monitored mount is currently
lowest. C<assign> / C<release> exist only to satisfy the resource
contract and to populate C<status> with the list of jobs running
under the gate; no bytes are reserved per assignment.

=head1 CLI

C<-R Disk=ENTRY,ENTRY,...> -- each ENTRY is one of:

=over 4

=item C</path:THRESHOLD>

Inline mount specification.

=item C<@/path/to/file.json>

Load a JSON config file. The file's top-level shape is:

    {
      "mounts": {
        "/tmp": { "min_free": "25%" },
        "/var": { "min_free": "1gb" }
      }
    }

=back

Inline and C<@file> entries may be combined. Per-mount-key, later
entries override earlier ones (file values lose to inline values).

=head1 THRESHOLDS

A threshold is C<NUMBER[UNIT]>:

=over 4

=item *

C<25> -- 25% free required (default unit = %)

=item *

C<25%> -- 25% free required (must satisfy C<< 0 < pct < 100 >>)

=item *

C<512kb>, C<512mb>, C<1gb>, C<2tb> -- absolute free bytes required
(case-insensitive)

=back

=head1 OPTIONAL DEPENDENCY

This resource requires L<Filesys::Df>, which is not a hard dependency
of this distribution. Normal C<yath> use that does not request
C<-R Disk> works without it. Install via C<cpanm Filesys::Df> when
this resource is needed.

=head1 NETWORK FILESYSTEMS

Do not use this resource on network filesystems (NFS, CIFS/SMB,
sshfs, glusterfs, ceph, davfs, 9p, beegfs, lustre, afs, coda, or any
fuse-based remote mount). Two reasons:

=over 4

=item *

Every C<available()> call performs a C<statvfs(2)> on each tracked
mount. On a fast local filesystem this is a single µs-scale syscall
and disappears in the noise. On a network filesystem each call may
block on a network round-trip, multiplying scheduler latency by
orders of magnitude.

=item *

Free-space readings on network filesystems are typically cached on
the client and refreshed on a server-side timer. The reading
C<statvfs> reports may be seconds out of date, defeating the
threshold gate's intended invariant.

=back

If you need disk-space gating against a network mount, run a small
local cache or scratch volume and gate against that instead.

=head1 ATTRIBUTES

=over 4

=item mounts (required)

Hashref of C<< { '/path' => { min_free => THRESHOLD } } >> where
THRESHOLD is a parsed hashref of the form
C<< { kind => 'pct'|'bytes', value => N } >> (as returned by
L<Test2::Harness2::Util::Units/parse_size_or_pct> with
C<< default_unit => '%' >>). Must be non-empty.

=back

=head1 METHODS

Implements L<Test2::Harness2::Role::Resource>.

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

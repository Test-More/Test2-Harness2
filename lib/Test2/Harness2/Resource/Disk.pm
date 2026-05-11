package Test2::Harness2::Resource::Disk;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Time::HiRes ();

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Resource::Disk::Threshold qw/parse_threshold evaluate_threshold/;

use Object::HashBase qw{
    <mounts
    <poll_interval
    <assignments
    <samples
    +broken
    +permanent
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

# Test seam: tests assign \&Custom to override. Production callers
# never touch this; the default is Time::HiRes::time.
our $CLOCK = \&Time::HiRes::time;

sub _now { $CLOCK->() }

sub resource_name { 'disk' }

# Keys this resource accepts at construction time. Anything else
# (slots, job_slots, classes, utilize, no_resource, ...) is noise
# from the resource group settings hash being passed through verbatim
# by App::Yath2::Command::start::resources -- silently dropped.
my %CTOR_KEYS = map { $_ => 1 } qw/mounts poll_interval/;

# Class method called by App::Yath2::Command::test::_build_resources
# and App::Yath2::Command::start::resources. Translates the raw arg
# list (positional inline entries + arbitrary k=>v from the resource
# group settings) into a key/value list ready for Disk->new.
sub parse_options {
    my ($class, @args) = @_;

    my %ctor;
    my %file_mounts;
    my %inline_mounts;
    my $file_seen_poll;
    my $user_poll_set = 0;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        # Known k=>v pair: consume both.
        if (   defined $arg
            && !ref($arg)
            && exists $CTOR_KEYS{$arg}
            && $i + 1 < @args)
        {
            $ctor{$arg} = $args[$i + 1];
            $user_poll_set = 1 if $arg eq 'poll_interval';
            $i += 2;
            next;
        }

        # Drop unknown k=>v pairs from the resource-group settings.
        # Heuristic: a defined non-ref scalar that does not look like a
        # positional entry (no leading / or @) and has a following value
        # gets dropped as a pair.
        if (   defined $arg
            && !ref($arg)
            && $arg !~ m{^/}
            && $arg !~ m{^\@}
            && $i + 1 < @args)
        {
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
            my $path = $1;
            my ($pi, $mounts) = $class->_load_config_file($path);
            $file_seen_poll = $pi if defined $pi;
            $file_mounts{$_} = $mounts->{$_} for keys %$mounts;
        }
        elsif ($arg =~ m{^(/.+?):(.+)\z}) {
            my ($path, $threshold) = ($1, $2);
            my $parsed = eval { parse_threshold($threshold) };
            croak "Resource::Disk: bad threshold in entry '$arg': $@" if $@;
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

    $ctor{mounts} = \%mounts if %mounts;

    # poll_interval precedence: user-supplied wins; else file value if any; else default 5.
    if (!$user_poll_set) {
        $ctor{poll_interval} = defined($file_seen_poll) ? $file_seen_poll : 5;
    }

    return %ctor;
}

sub _load_config_file {
    my ($class, $path) = @_;

    croak "Resource::Disk config file '$path' does not exist"  unless -e $path;
    croak "Resource::Disk config file '$path' is not readable" unless -r _;

    open my $fh, '<:raw', $path
        or croak "Resource::Disk: cannot open config file '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    my $data = eval { decode_json($body) };
    croak "Resource::Disk: cannot parse JSON in '$path': $@" if $@;
    croak "Resource::Disk: top-level of '$path' must be a JSON object"
        unless ref($data) eq 'HASH';

    my %top_allowed = map { $_ => 1 } qw/poll_interval mounts/;
    for my $k (sort keys %$data) {
        croak "Resource::Disk: unknown key '$k' in '$path'"
            unless $top_allowed{$k};
    }

    my $pi = $data->{poll_interval};
    if (defined $pi) {
        croak "Resource::Disk: poll_interval in '$path' must be a positive number"
            unless $pi =~ m/^[0-9]+(?:\.[0-9]+)?\z/ && $pi > 0;
    }

    my $raw_mounts = $data->{mounts} // {};
    croak "Resource::Disk: mounts in '$path' must be a JSON object"
        unless ref($raw_mounts) eq 'HASH';

    my %mounts;
    my %mount_allowed = map { $_ => 1 } qw/min_free/;
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
        my $threshold = eval { parse_threshold($cfg->{min_free}) };
        croak "Resource::Disk: bad threshold for mount '$mp' in '$path': $@"
            if $@;
        $mounts{$mp} = {min_free => $threshold};
    }

    return ($pi, \%mounts);
}

sub init {
    my $self = shift;

    $self->{+MOUNTS}        //= {};
    $self->{+POLL_INTERVAL} //= 5;
    $self->{+ASSIGNMENTS}   //= {};
    $self->{+SAMPLES}       //= {};

    croak "Resource::Disk: 'mounts' is required and must be non-empty"
        unless ref($self->{+MOUNTS}) eq 'HASH' && keys %{$self->{+MOUNTS}};

    croak "Resource::Disk: 'poll_interval' must be a positive number"
        unless $self->{+POLL_INTERVAL} =~ m/^[0-9]+(?:\.[0-9]+)?\z/
        && $self->{+POLL_INTERVAL} > 0;

    # Defer Filesys::Df load until init so the option-loader (which
    # require()s every Resource class to discover its options) does
    # not blow up when this optional dep is missing.
    my $loaded = eval { require Filesys::Df; 1 };
    croak "Resource::Disk requires Filesys::Df; install it (cpanm Filesys::Df) and retry"
        unless $loaded;

    # Validate every configured mount: must exist and statvfs cleanly
    # right now. A typo in the mount path is a configuration error,
    # not a runtime defer.
    for my $mp (sort keys %{$self->{+MOUNTS}}) {
        croak "Resource::Disk: mount '$mp' does not exist" unless -e $mp;
        my $sample = eval { Filesys::Df::df($mp, 1) };
        croak "Resource::Disk: mount '$mp' could not be sampled: $@" if $@;
        croak "Resource::Disk: mount '$mp' returned no sample"
            unless ref($sample) eq 'HASH' && defined $sample->{bavail};
    }
}

sub available {
    my ($self, %p) = @_;

    croak "'job' is required" unless defined $p{job};

    # Refresh every mount before deciding so status() sees fresh
    # samples regardless of which mount is the first to fail.
    $self->_refresh_sample($_) for keys %{$self->{+MOUNTS}};

    for my $mp (keys %{$self->{+MOUNTS}}) {
        my $sample = $self->{+SAMPLES}->{$mp};
        return 0 if !$sample || ($sample->{state} // 'unknown') ne 'ok';
    }

    return 1;
}

# Sample one mount, respecting the TTL. On statvfs failure increment
# consecutive_failures; at >= 3 flip the resource to permanent_broken.
sub _refresh_sample {
    my ($self, $mp) = @_;

    my $now   = _now();
    my $cache = $self->{+SAMPLES}->{$mp};
    my $stale = !$cache || ($now - ($cache->{ts} // 0)) > $self->{+POLL_INTERVAL};

    return $cache unless $stale;

    # Pass block_size = 1 so Filesys::Df returns counts in bytes
    # directly. Avoids any ambiguity about whether bavail / blocks /
    # user_bavail / user_blocks are blocks or bytes.
    my $sample = eval { Filesys::Df::df($mp, 1) };
    my $err    = $@;

    if (!$sample || ref($sample) ne 'HASH' || !defined $sample->{bavail}) {
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
    my $state     = evaluate_threshold($threshold, $free, $total);

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

# Disk supports all four transitions because the failure-counter
# inside available() flips permanent_broken from inside the resource.
sub is_broken           { $_[0]->{+BROKEN} || $_[0]->{+PERMANENT} ? 1 : 0 }
sub is_permanent_broken { $_[0]->{+PERMANENT}                     ? 1 : 0 }
sub is_paused           { $_[0]->{+PAUSED}                        ? 1 : 0 }

sub mark_broken           { $_[0]->{+BROKEN} = 1 }
sub mark_permanent_broken { $_[0]->{+BROKEN} = $_[0]->{+PERMANENT} = 1 }
sub mark_paused           { $_[0]->{+PAUSED} = 1 }

# Clears transient broken/paused but leaves permanent_broken intact.
sub mark_resumed {
    my $self = shift;
    $self->{+PAUSED} = 0;
    $self->{+BROKEN} = 0 unless $self->{+PERMANENT};
}

# Stubs filled in by later tasks. Keeping them present (even as
# croaks) lets Task 3 commit a passing options.t while the rest of
# the contract is still being built out.
sub assign  { croak "Resource::Disk::assign not yet implemented (Task 6)" }
sub release { croak "Resource::Disk::release not yet implemented (Task 6)" }
sub status  { croak "Resource::Disk::status not yet implemented (Task 7)" }

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
below a per-mount threshold. Sampling is inline via L<Filesys::Df>
with a per-mount TTL cache keyed off C<poll_interval> seconds
(default 5).

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
      "poll_interval": 5,
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

=head1 ATTRIBUTES

=over 4

=item mounts (required)

Hashref of C<< { '/path' => { min_free => THRESHOLD } } >> where
THRESHOLD is a parsed hashref from
L<Test2::Harness2::Resource::Disk::Threshold/parse_threshold>.
Must be non-empty.

=item poll_interval

Seconds between disk samples per mount. Defaults to C<5>.

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

package Test2::Harness2::Runner::Resource::Disk;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Units qw/parse_size_or_pct/;

use Object::HashBase qw{
    &Test2::Harness2::Runner::Resource
    <settings
    <state
    <arg
    <name
    <mounts
    <samples
    +supported
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Resource::Disk - Throttle new test starts when free disk
space on a tracked mount is low.

=head1 DESCRIPTION

Gates new test launches when free space on any tracked mount drops below a
per-mount threshold. The threshold is a percentage of total space (C<25%>) or an
absolute byte size (C<512mb>/C<1gb>); a bare number defaults to a percentage.

This is a I<gate>, not a slot pool: every job is either allowed or deferred based
on whichever monitored mount is currently lowest. C<assign>/C<release> exist only
to satisfy the resource contract; no bytes are reserved per assignment. Each
availability check samples every tracked mount fresh (there is no TTL cache), so
the metrics are read B<in-resource, runner-local>.

After three consecutive sample failures for a mount the resource gives up on that
mount and reports it permanently unavailable (C<available> returns C<-1>), which
skips dependent tests (or fails them under C<--fail-on-resource-skip>).

=head1 SUPPORTED PLATFORMS

Free/total bytes come from L<Filesys::Df> (an B<optional> dependency, not required
by this distribution). It is lazy-required whenever the Disk resource is used at
all -- both absolute and percentage thresholds need free/total bytes and there is
no portable core C<statvfs> -- with an actionable error if it is missing.

Do B<not> use this resource on network filesystems (NFS/CIFS/sshfs/fuse): each
check performs a C<statvfs(2)> per mount which blocks on a network round-trip and
may return stale client-cached data. Gate against a local scratch volume instead.

=head1 SYNOPSIS

    yath test -R Disk=/tmp:25%
    yath test -R Disk=/tmp:25%,/var:1gb
    yath test -R Disk=/scratch:512mb

=head1 ATTRIBUTES

=over 4

=item mounts

Non-empty hashref C<< { '/path' => { min_free => THRESHOLD } } >> where THRESHOLD
is a parsed C<< {kind, value} >> from
L<Test2::Harness2::Util::Units/parse_size_or_pct>.

=back

=cut

sub init ($self) {
    $self->{+NAME}    //= 'disk';
    $self->{+MOUNTS}  //= {};
    $self->{+SAMPLES} //= {};

    $self->_parse_inline_arg;

    croak "Resource::Disk: at least one mount is required (e.g. -R Disk=/tmp:25%)"
        unless keys %{$self->{+MOUNTS}};

    # Filesys::Df is an optional dep; the option loader require()s every Resource
    # class just to read its options, so we must NOT load it at compile time.
    # Lazy-require it here (Disk is only constructed when actually requested) with
    # an actionable error.
    $self->_require_filesys_df;

    for my $mp (sort keys %{$self->{+MOUNTS}}) {
        croak "Resource::Disk: mount '$mp' does not exist" unless -e $mp;
    }

    return;
}

# Parse the inline '-R Disk=ARG' string. ARG is a comma-separated list of
# '/path:THRESHOLD' entries. THRESHOLD defaults to a percentage when no unit is
# given.
sub _parse_inline_arg ($self) {
    my $arg = $self->{+ARG};
    return unless defined $arg && length $arg;

    for my $entry (split /,/, $arg) {
        $entry =~ s/^\s+//;
        $entry =~ s/\s+$//;
        next unless length $entry;

        if ($entry =~ m{^(/.+?):(.+)\z}) {
            my ($path, $raw) = ($1, $2);
            my $parsed;
            my $ok  = eval { $parsed = parse_size_or_pct($raw, default_unit => '%', name => 'threshold'); 1 };
            my $err = $@;
            croak "Resource::Disk: bad threshold in entry '$entry': $err" unless $ok;
            $self->{+MOUNTS}->{$path} = {min_free => $parsed};
        }
        else {
            croak "Resource::Disk: unrecognised inline entry '$entry' (expected /path:THRESHOLD)";
        }
    }

    return;
}

# Lazy-require Filesys::Df with an actionable error. Returns nothing; croaks on
# missing dep.
sub _require_filesys_df ($self) {
    my $loaded = eval { require Filesys::Df; 1 };
    my $err    = $@;
    return if $loaded;

    # Surface broken-install / XS errors so they are not masked by the install hint.
    warn $err if $err && $err !~ m{\bCan't locate Filesys/Df\.pm\b};
    croak "Resource::Disk requires Filesys::Df (an optional dependency); install it "
        . "(cpanm Filesys::Df) and retry";
}

=head1 PUBLIC METHODS

The instance's configured name is available via the generated C<name> reader
(defaults to C<disk>).

=over 4

=item $bool = $self->is_supported

True (Disk requires only L<Filesys::Df>, already verified in C<init>). Present for
parity with the other OS-limit resources.

=item $val = $self->available(\%task)

C<1> when every tracked mount has headroom, C<0> to defer when a mount is low, or
C<-1> when a mount has failed to sample three times in a row (permanent skip).

=item $self->assign(\%task, \%state)

Satisfies the contract; reserves nothing.

=back

=cut

sub is_supported ($self) {
    return $self->{+SUPPORTED} //= 1;
}

sub available ($self, $task = undef) {
    croak "a task is required" unless defined $task;

    # Sample every mount so status() reflects fresh readings for all of them.
    $self->_take_sample($_) for sort keys %{$self->{+MOUNTS}};

    my $result = 1;
    for my $mp (sort keys %{$self->{+MOUNTS}}) {
        my $sample = $self->{+SAMPLES}->{$mp};
        my $state  = $sample ? ($sample->{state} // 'unknown') : 'unknown';

        if (($sample->{consecutive_failures} // 0) >= 3) {
            return -1;    # permanently broken mount -> skip dependent tests
        }

        $result = 0 if $state ne 'ok';
    }

    return $result;
}

sub assign ($self, $task, $state) {
    # Gate only: nothing to reserve. Still record so a status view could track it.
    $state->{record} = {job_id => $task->{job_id}, stamp => time};
    return;
}

# record() / release() are the base role's no-op defaults
# (Test2::Harness2::Runner::Resource): this gate reserves nothing per job.

sub status_data ($self) {
    my $now = time;
    my @rows;
    for my $mp (sort keys %{$self->{+MOUNTS}}) {
        my $threshold = $self->{+MOUNTS}->{$mp}->{min_free};
        my $cache     = $self->{+SAMPLES}->{$mp} // {};
        push @rows => [
            $mp,
            $self->_threshold_str($threshold),
            $cache->{free_bytes}  // '--',
            $cache->{total_bytes} // '--',
            defined($cache->{used_pct}) ? sprintf('%.1f%%', $cache->{used_pct}) : '--',
            $cache->{state} // 'unknown',
            $cache->{consecutive_failures} // 0,
        ];
    }

    return [
        {
            tables => [
                {
                    header => [qw/Mount MinFree FreeBytes TotalBytes Used State Fails/],
                    rows   => \@rows,
                    title  => $self->{+NAME},
                },
            ],
        },
    ];
}

=head1 PRIVATE METHODS

=over 4

=item $sample = $self->_take_sample($mount)

Sample one mount via L<Filesys::Df>, update the per-mount cache and its
consecutive-failure counter, and return the sample hashref.

=item $state = $self->_evaluate_threshold($threshold, $free_bytes, $total_bytes)

Return C<'ok'> or C<'low'> for a parsed threshold against the sampled bytes.

=item $str = $self->_threshold_str($threshold)

Human-readable form of a parsed threshold for status output.

=back

=cut

sub _take_sample ($self, $mp) {
    my $now   = time;
    my $cache = $self->{+SAMPLES}->{$mp};

    # block_size = 1: Filesys::Df returns bavail/blocks in bytes, not blocks.
    my $sample;
    my $ok  = eval { $sample = Filesys::Df::df($mp, 1); 1 };
    my $err = $@;

    if (!$ok || !$sample || ref($sample) ne 'HASH' || !defined $sample->{bavail}) {
        my $fails = ($cache->{consecutive_failures} // 0) + 1;
        return $self->{+SAMPLES}->{$mp} = {
            ts                   => $now,
            free_bytes           => $cache ? $cache->{free_bytes}  : undef,
            total_bytes          => $cache ? $cache->{total_bytes} : undef,
            used_pct             => undef,
            state                => 'unknown',
            consecutive_failures => $fails,
            last_error           => $err || 'sample returned no data',
        };
    }

    my $free  = $sample->{bavail};
    my $total = $sample->{blocks};

    my $threshold = $self->{+MOUNTS}->{$mp}->{min_free};
    my $state     = $self->_evaluate_threshold($threshold, $free, $total);

    return $self->{+SAMPLES}->{$mp} = {
        ts                   => $now,
        free_bytes           => $free,
        total_bytes          => $total,
        used_pct             => $total ? (($total - $free) / $total) * 100 : undef,
        state                => $state,
        consecutive_failures => 0,
        last_error           => undef,
    };
}

sub _evaluate_threshold ($self, $threshold, $free_bytes, $total_bytes) {
    croak "Resource::Disk: evaluate_threshold requires a parsed threshold hashref"
        unless ref($threshold) eq 'HASH' && defined $threshold->{kind} && defined $threshold->{value};

    croak "Resource::Disk: evaluate_threshold requires non-negative free_bytes"
        unless defined $free_bytes && $free_bytes >= 0;

    if ($threshold->{kind} eq 'pct') {
        return 'low' unless defined $total_bytes && $total_bytes > 0;
        my $free_pct = ($free_bytes / $total_bytes) * 100;
        return $free_pct >= $threshold->{value} ? 'ok' : 'low';
    }

    return $free_bytes >= $threshold->{value} ? 'ok' : 'low'
        if $threshold->{kind} eq 'bytes';

    croak "Resource::Disk: unknown threshold kind '$threshold->{kind}'";
}

sub _threshold_str ($self, $t) {
    return '--' unless ref($t) eq 'HASH';
    return $t->{kind} eq 'pct' ? "$t->{value}%" : "$t->{value}b";
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

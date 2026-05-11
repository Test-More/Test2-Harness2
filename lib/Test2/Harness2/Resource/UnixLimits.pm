package Test2::Harness2::Resource::UnixLimits;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Time::HiRes ();

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Units qw/parse_count_or_pct parse_size_or_pct/;

use Object::HashBase qw{
    <nproc
    <nofile
    <as
    <assignments
    +utilize_percent
    +name
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';
with 'Test2::Harness2::Role::Resource::Utilizer';

# Comment needed
our $CLOCK = \&Time::HiRes::time;
sub _now { $CLOCK->() }

sub resource_name { $_[0]->{+NAME} // 'unixlimits' }

# Bad name
my %CTOR_KEYS = map { $_ => 1 } qw/nproc nofile as name utilize_percent/;

sub parse_options {
    my ($class, @args) = @_;

    # Bad name
    my %ctor;
    my %file_vals;
    my (%inline, $inline_name);

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        # multi-line cond in paren is bad
        if (   defined $arg
            && !ref($arg)
            && $arg !~ m{^[0-9]}
            && $arg !~ m{^@}
            && $arg !~ m{^name=}
            && $arg !~ m{^nproc=}
            && $arg !~ m{^nofile=}
            && $arg !~ m{^as=}
            && $i + 1 < @args)
        {
            $ctor{$arg} = $args[$i + 1] if exists $CTOR_KEYS{$arg};
            $i += 2;
            next;
        }

        croak "Resource::UnixLimits: undef positional entry" unless defined $arg;
        croak "Resource::UnixLimits: ref positional entry" if ref $arg;

        if ($arg =~ m{^\@(.+)\z}) {
            %file_vals = %{$class->_load_config_file($1)};
        }
        elsif ($arg =~ m{^name=(.*)\z}) {
            my $n = $1;
            croak "Resource::UnixLimits: empty name=" unless defined $n && length $n;
            croak "Resource::UnixLimits: name='$n' must be whitespace-free" if $n =~ /\s/;
            $inline_name = $n;
        }
        elsif ($arg =~ m{^(nproc|nofile)=(.+)\z}) {
            my ($dim, $raw) = ($1, $2);
            my $parsed = eval { parse_count_or_pct($raw, name => $dim) };
            croak "Resource::UnixLimits: bad $dim in '$arg': $@" if $@;
            $inline{$dim} = $parsed;
        }
        elsif ($arg =~ m{^as=(.+)\z}) {
            my $parsed = eval { parse_size_or_pct($1, name => 'as') };
            croak "Resource::UnixLimits: bad as in '$arg': $@" if $@;
            $inline{as} = $parsed;
        }
        elsif ($arg =~ m{^([0-9]+(?:\.[0-9]+)?)%\z}) {
            # Bare-pct shorthand applies to nproc + nofile (not as).
            my $pct = $1;
            croak "Resource::UnixLimits: pct must be > 0 and < 100 (got '$pct')"
                unless $pct > 0 && $pct < 100;
            $inline{nproc}  = {kind => 'pct', value => $pct + 0};
            $inline{nofile} = {kind => 'pct', value => $pct + 0};
        }
        else {
            croak "Resource::UnixLimits: unrecognised entry '$arg'";
        }

        $i += 1;
    }

    # File then inline.
    for my $dim (qw/nproc nofile as name/) {
        $ctor{$dim} = $file_vals{$dim} if exists $file_vals{$dim};
    }
    for my $dim (qw/nproc nofile as/) {
        $ctor{$dim} = $inline{$dim} if exists $inline{$dim};
    }
    $ctor{name} = $inline_name if defined $inline_name;

    $ctor{nproc}  //= {kind => 'pct', value => 10};
    $ctor{nofile} //= {kind => 'pct', value => 10};
    $ctor{name}   //= 'unixlimits';

    return %ctor;
}

sub _load_config_file {
    my ($class, $path) = @_;

    croak "Resource::UnixLimits config file '$path' does not exist" unless -e $path;
    open my $fh, '<:raw', $path or croak "Resource::UnixLimits: cannot open '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    # Bad eval
    my $data = eval { decode_json($body) };
    croak "Resource::UnixLimits: cannot parse JSON in '$path': $@" if $@;
    croak "Resource::UnixLimits: top-level must be a JSON object"
        unless ref($data) eq 'HASH';

    my %allowed = map { $_ => 1 } qw/nproc nofile as name/;
    for my $k (sort keys %$data) {
        croak "Resource::UnixLimits: unknown key '$k' in '$path'" unless $allowed{$k};
    }

    my %out;
    for my $dim (qw/nproc nofile/) {
        if (defined $data->{$dim}) {
            # Bad eval
            my $parsed = eval { parse_count_or_pct($data->{$dim}, name => $dim) };
            croak "Resource::UnixLimits: bad $dim in '$path': $@" if $@;
            $out{$dim} = $parsed;
        }
    }
    if (defined $data->{as}) {
        # Bad eval
        my $parsed = eval { parse_size_or_pct($data->{as}, name => 'as') };
        croak "Resource::UnixLimits: bad as in '$path': $@" if $@;
        $out{as} = $parsed;
    }
    if (defined $data->{name}) {
        my $n = $data->{name};
        croak "Resource::UnixLimits: name in '$path' must be a non-empty whitespace-free string"
            unless !ref($n) && length($n) && $n !~ /\s/;
        $out{name} = $n;
    }
    return \%out;
}

# Init should be closer to the top of the file since the constructor is often reviewed. Fix this for others as well, should be below 1-liners, but above most other subs
sub init {
    my $self = shift;

    croak "Resource::UnixLimits requires Linux (this is $^O)" unless $^O eq 'linux';

    $self->{+ASSIGNMENTS} //= {};
    $self->{+NAME}        //= 'unixlimits';

    for my $dim (qw/nproc nofile/) {
        my $v = $self->{$dim};
        croak "Resource::UnixLimits: $dim is required" unless ref($v) eq 'HASH';
        croak "Resource::UnixLimits: $dim.kind must be 'count' or 'pct'"
            unless $v->{kind} && ($v->{kind} eq 'count' || $v->{kind} eq 'pct');
        croak "Resource::UnixLimits: $dim.value must be > 0" unless $v->{value} > 0;
    }
    if (my $as = $self->{+AS}) {
        croak "Resource::UnixLimits: AS.kind must be 'bytes' or 'pct'"
            unless ref($as) eq 'HASH' && $as->{kind} && ($as->{kind} eq 'bytes' || $as->{kind} eq 'pct');
        croak "Resource::UnixLimits: AS.value must be > 0" unless $as->{value} > 0;
    }
}

sub set_utilize_percent {
    my ($self, $pct) = @_;
    $self->{+UTILIZE_PERCENT} = $self->_validate_utilize_percent($pct);
    return;
}

# Test seams.
sub _read_self_limits {
    open my $fh, '<', '/proc/self/limits' or die "open /proc/self/limits: $!";
    my %out;
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
    return \%out;
}

sub _read_self_status {
    open my $fh, '<', '/proc/self/status' or die "open /proc/self/status: $!";
    my %out;
    while (my $line = <$fh>) {
        if ($line =~ m/^Threads:\s+([0-9]+)/)     { $out{Threads} = $1 + 0 }
        if ($line =~ m/^VmSize:\s+([0-9]+)\s*kB/) { $out{VmSize}  = $1 + 0 }
    }
    close $fh;
    return \%out;
}

sub _count_self_fd {
    opendir my $dh, '/proc/self/fd' or die "opendir /proc/self/fd: $!";
    my $n = 0;
    while (my $e = readdir $dh) {
        next if $e eq '.' || $e eq '..';
        $n++;
    }
    closedir $dh;
    return $n;
}

# Name this better, I do not know what this does from its name.
sub _eval_dim {
    my ($self, $dim, $soft_cap, $current) = @_;

    return (
        state              => 'ok', soft_cap => $soft_cap, current => $current,
        effective_min_free => 0,    headroom => $self->{$dim}
    ) unless defined $soft_cap;

    my $headroom = $self->{$dim};
    my $explicit =
          $headroom->{kind} eq 'count' ? $headroom->{value}
        : $headroom->{kind} eq 'bytes' ? $headroom->{value}
        :                                int($soft_cap * $headroom->{value} / 100);

    my $utilize = 0;
    if (defined $self->{+UTILIZE_PERCENT}) {
        $utilize = int($soft_cap * (100 - $self->{+UTILIZE_PERCENT}) / 100);
    }

    my $effective = $explicit > $utilize ? $explicit : $utilize;
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

# What does dim mean, better name
sub _dim_results {
    my $self = shift;

    my $limits  = $self->_read_self_limits;
    my $status  = $self->_read_self_status;
    my $fdcount = $self->_count_self_fd;

    my %dims;
    $dims{nproc}  = {$self->_eval_dim('nproc',  $limits->{nproc},  $status->{Threads} // 0)};
    $dims{nofile} = {$self->_eval_dim('nofile', $limits->{nofile}, $fdcount)};
    if ($self->{+AS}) {
        my $vmsize_bytes = ($status->{VmSize} // 0) * 1024;
        $dims{as} = {$self->_eval_dim('as', $limits->{as}, $vmsize_bytes)};
    }
    return \%dims;
}

sub is_temporarily_unavailable {
    my $self = shift;
    my $dims = $self->_dim_results;
    for my $d (values %$dims) {
        return 1 if $d->{state} eq 'low';
    }
    return 0;
}

sub available {
    my ($self, %p) = @_;
    croak "'job' is required" unless defined $p{job};
    return 1;
}

sub assign {
    my ($self, %p) = @_;
    my $id  = $p{id}  or croak "'id' is required";
    my $job = $p{job} or croak "'job' is required";
    croak "'env' hashref is required" unless ref($p{env}) eq 'HASH';
    croak "Resource::UnixLimits: duplicate assign for id '$id'"
        if exists $self->{+ASSIGNMENTS}->{$id};
    $self->{+ASSIGNMENTS}->{$id} = {job => $job, assigned_at => _now()};
    return 1;
}

sub release {
    my ($self, %p) = @_;
    my $id = $p{id} or croak "'id' is required";
    delete $self->{+ASSIGNMENTS}->{$id}
        or croak "Resource::UnixLimits: invalid release id '$id'";
    return 1;
}

# 1 line subs higher, below hashbase and other imports, but above multi-line subs
sub is_paused    { $_[0]->{+PAUSED} ? 1 : 0 }
sub mark_paused  { $_[0]->{+PAUSED} = 1 }
sub mark_resumed { $_[0]->{+PAUSED} = 0 }

sub status {
    my $self = shift;

    my $dims = $self->_dim_results;

    my @assignments;
    for my $id (sort keys %{$self->{+ASSIGNMENTS}}) {
        my $a  = $self->{+ASSIGNMENTS}->{$id};
        my $tf = $a->{job}->test_file;
        push @assignments => {
            id          => $id,
            test        => $tf->relative,
            assigned_at => $a->{assigned_at},
            age         => _now() - $a->{assigned_at},
        };
    }

    return {
        resource          => $self->resource_name,
        utilize_percent   => $self->{+UTILIZE_PERCENT},
        paused            => $self->is_paused,
        dimensions        => $dims,
        total_assignments => scalar(keys %{$self->{+ASSIGNMENTS}}),
        assignments       => \@assignments,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::UnixLimits - Throttle jobs against per-process Unix ulimits.

=head1 SYNOPSIS

    yath -D test -j16 -R UnixLimits
    yath -D test -j16 -R UnixLimits=10%
    yath -D test -j16 -R UnixLimits=nproc=128,nofile=10%
    yath -D test -j16 -R UnixLimits=as=512mb

=head1 DESCRIPTION

Defers new test starts when the harness process is close to one of
its soft ulimits. Three dimensions: C<nproc> (Threads:), C<nofile>
(count of C</proc/self/fd>), and C<as> (VmSize: vs RLIMIT_AS).

C<nproc> and C<nofile> are checked by default with a 10% headroom.
C<as> is off by default and enabled only when an explicit threshold
is supplied.

Each dimension's threshold may be expressed as a count, bytes (for
C<as>), or a percentage. C<--utilize PCT> layers on top:
effective threshold per dimension is C<max(explicit, utilize-derived)>.

=head1 LIMITATIONS

Linux only. macOS / BSD / Solaris are deferred to per-platform
subclasses.

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

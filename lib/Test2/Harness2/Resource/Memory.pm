package Test2::Harness2::Resource::Memory;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Time::HiRes ();

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Units qw/parse_size_or_pct/;

use Object::HashBase qw{
    <min_free
    <assignments
    +utilize_percent
    +name
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';
with 'Test2::Harness2::Role::Resource::Utilizer';

# Comment that this is needed for tests
our $CLOCK = \&Time::HiRes::time;
sub _now { $CLOCK->() }

sub resource_name { $_[0]->{+NAME} // 'memory' }

# Bad variable name again
my %CTOR_KEYS = map { $_ => 1 } qw/min_free name utilize_percent/;

sub parse_options {
    my ($class, @args) = @_;

    # Bad var name again
    my %ctor;
    my %file_vals;
    my $inline_threshold;
    my $inline_name;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        # Bad multi-line conditional in parents, see CPU comment
        # Drop unknown k=>v pairs from the resource-group settings.
        if (
               defined $arg
            && !ref($arg)
            && $arg !~ m{^[0-9]}        # not a bare threshold
            && $arg !~ m{^@}            # not a file
            && $arg !~ m{^name=}        # not name=
            && $arg !~ m{^min_free=}    # not min_free=
            && $i + 1 < @args
            )
        {
            $ctor{$arg} = $args[$i + 1] if exists $CTOR_KEYS{$arg};
            $i += 2;
            next;
        }

        croak "Resource::Memory: undef positional entry" unless defined $arg;
        croak "Resource::Memory: ref positional entry" if ref $arg;

        if ($arg =~ m{^\@(.+)\z}) {
            %file_vals = %{$class->_load_config_file($1)};
        }
        elsif ($arg =~ m{^name=(.*)\z}) {
            my $n = $1;
            croak "Resource::Memory: empty name=" unless defined $n && length $n;
            croak "Resource::Memory: name='$n' must be whitespace-free" if $n =~ /\s/;
            $inline_name = $n;
        }
        elsif ($arg =~ m{^min_free=(.+)\z}) {
            my $parsed = eval { parse_size_or_pct($1, name => 'min_free') };
            croak "Resource::Memory: bad min_free in '$arg': $@" if $@;
            $inline_threshold = $parsed;
        }
        elsif ($arg =~ m{^[0-9]}) {
            # Bare-threshold shorthand: <pct%> or <size>.
            my $parsed = eval { parse_size_or_pct($arg, name => 'min_free') };
            croak "Resource::Memory: bad threshold '$arg': $@" if $@;
            $inline_threshold = $parsed;
        }
        else {
            croak "Resource::Memory: unrecognised entry '$arg'";
        }

        $i += 1;
    }

    # Precedence: file then inline.
    $ctor{min_free} = $file_vals{min_free} if exists $file_vals{min_free};
    $ctor{name}     = $file_vals{name}     if exists $file_vals{name};
    $ctor{min_free} = $inline_threshold    if defined $inline_threshold;
    $ctor{name}     = $inline_name         if defined $inline_name;

    $ctor{min_free} //= {kind => 'pct', value => 5};
    $ctor{name}     //= 'memory';

    return %ctor;
}

sub _load_config_file {
    my ($class, $path) = @_;

    croak "Resource::Memory config file '$path' does not exist" unless -e $path;
    open my $fh, '<:raw', $path or croak "Resource::Memory: cannot open '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    # Bad use fo eval, see STYLE_GUIDE and other review comments
    my $data = eval { decode_json($body) };
    croak "Resource::Memory: cannot parse JSON in '$path': $@" if $@;
    croak "Resource::Memory: top-level of '$path' must be a JSON object"
        unless ref($data) eq 'HASH';

    my %allowed = map { $_ => 1 } qw/min_free name/;
    for my $k (sort keys %$data) {
        croak "Resource::Memory: unknown key '$k' in '$path'" unless $allowed{$k};
    }

    my %out;
    if (defined $data->{min_free}) {
        # Bad eval again
        my $parsed = eval { parse_size_or_pct($data->{min_free}, name => 'min_free') };
        croak "Resource::Memory: bad min_free in '$path': $@" if $@;
        $out{min_free} = $parsed;
    }
    if (defined $data->{name}) {
        my $n = $data->{name};
        croak "Resource::Memory: name in '$path' must be a non-empty whitespace-free string"
            unless !ref($n) && length($n) && $n !~ /\s/;
        $out{name} = $n;
    }

    return \%out;
}

sub init {
    my $self = shift;

    croak "Resource::Memory requires Linux (this is $^O)" unless $^O eq 'linux';

    $self->{+ASSIGNMENTS} //= {};
    $self->{+NAME}        //= 'memory';

    my $mf = $self->{+MIN_FREE};
    croak "Resource::Memory: 'min_free' is required"
        unless ref($mf) eq 'HASH';
    croak "Resource::Memory: min_free.kind must be 'pct' or 'bytes'"
        unless defined $mf->{kind} && ($mf->{kind} eq 'pct' || $mf->{kind} eq 'bytes');
    croak "Resource::Memory: min_free.value must be > 0"
        unless defined $mf->{value} && $mf->{value} > 0;
    if ($mf->{kind} eq 'pct') {
        croak "Resource::Memory: min_free.value (pct) must be < 100"
            unless $mf->{value} < 100;
    }
}

sub set_utilize_percent {
    my ($self, $pct) = @_;
    $self->{+UTILIZE_PERCENT} = $self->_validate_utilize_percent($pct);
    return;
}

# Test seam: tests override this. Production reads /proc/meminfo.
sub _read_meminfo {
    open my $fh, '<', '/proc/meminfo' or die "open /proc/meminfo: $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body;
}

sub _sample {
    my $self = shift;
    my $body = $self->_read_meminfo;

    my %vals;
    for my $line (split /\n/, $body) {
        if ($line =~ m/^(\w+):\s*([0-9]+)\s*kB\s*\z/) {
            $vals{$1} = $2 * 1024;    # bytes
        }
    }

    croak "Resource::Memory: missing MemTotal in /proc/meminfo"
        unless defined $vals{MemTotal};
    croak "Resource::Memory: missing MemAvailable in /proc/meminfo"
        unless defined $vals{MemAvailable};

    return ($vals{MemTotal}, $vals{MemAvailable});
}

sub _effective_min_free_bytes {
    my ($self, $total) = @_;

    my $mf = $self->{+MIN_FREE};
    my $explicit_bytes =
          $mf->{kind} eq 'bytes'
        ? $mf->{value}
        : int($total * $mf->{value} / 100);

    my $utilize_bytes = 0;
    if (defined $self->{+UTILIZE_PERCENT}) {
        $utilize_bytes = int($total * (100 - $self->{+UTILIZE_PERCENT}) / 100);
    }

    return $explicit_bytes > $utilize_bytes ? $explicit_bytes : $utilize_bytes;
}

sub is_temporarily_unavailable {
    my $self = shift;
    my ($total, $available) = $self->_sample;
    my $threshold = $self->_effective_min_free_bytes($total);
    return $available < $threshold ? 1 : 0;
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
    croak "Resource::Memory: duplicate assign for id '$id'"
        if exists $self->{+ASSIGNMENTS}->{$id};
    $self->{+ASSIGNMENTS}->{$id} = {job => $job, assigned_at => _now()};
    return 1;
}

sub release {
    my ($self, %p) = @_;
    my $id = $p{id} or croak "'id' is required";
    delete $self->{+ASSIGNMENTS}->{$id}
        or croak "Resource::Memory: invalid release id '$id'";
    return 1;
}

# 1 line subs should be at top of file, or top of a fold section
sub is_paused    { $_[0]->{+PAUSED} ? 1 : 0 }
sub mark_paused  { $_[0]->{+PAUSED} = 1 }
sub mark_resumed { $_[0]->{+PAUSED} = 0 }

sub status {
    my $self = shift;
    my ($total, $available) = $self->_sample;
    my $threshold = $self->_effective_min_free_bytes($total);

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
        resource                 => $self->resource_name,
        min_free                 => $self->{+MIN_FREE},
        utilize_percent          => $self->{+UTILIZE_PERCENT},
        mem_total_bytes          => $total,
        mem_available_bytes      => $available,
        effective_min_free_bytes => $threshold,
        paused                   => $self->is_paused,
        total_assignments        => scalar(keys %{$self->{+ASSIGNMENTS}}),
        assignments              => \@assignments,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::Memory - Throttle jobs when free memory is low.

=head1 SYNOPSIS

    yath -D test -j16 -R Memory                       # default min_free=5%
    yath -D test -j16 -R Memory=20%                   # min_free=20%
    yath -D test -j16 -R Memory=512mb                 # absolute min_free
    yath -D test -j16 -R Memory=20% -U 80             # both layered

=head1 DESCRIPTION

Defers new test starts when free memory drops below a per-instance
threshold. Sampling is inline via C</proc/meminfo>; no cache. Linux
only.

The threshold can be expressed as a percent of C<MemTotal>
(C<25%>) or as an absolute byte size (C<512mb>, C<2gb>). When
C<--utilize> is also set, both thresholds apply and the more
conservative wins.

=head1 LIMITATIONS

Linux only. Constructing this resource on any other OS croaks at
C<init>. Cross-platform support is future work (separate
per-platform subclasses).

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

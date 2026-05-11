package Test2::Harness2::Resource::Memory;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Harness2::Util::JSON      qw/decode_json/;
use Test2::Harness2::Util::Units     qw/parse_size_or_pct/;
use Test2::Harness2::Util::HiResTime qw/hi_res_time/;

use Object::HashBase qw{
    <min_free
    <assignments
    +utilize_percent
    +name
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource::Assignable';
with 'Test2::Harness2::Role::Resource';
with 'Test2::Harness2::Role::Resource::Utilizer';

sub resource_name { $_[0]->{+NAME} // 'memory' }

my %OPTION_KEYS = map { $_ => 1 } qw/min_free name utilize_percent/;

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

sub _is_unknown_kv_arg {
    my ($class, $arg, $has_next) = @_;
    return 0 unless $has_next;
    return 0 unless defined $arg;
    return 0 if ref $arg;
    return 0 if $arg =~ m{^[0-9]};
    return 0 if $arg =~ m{^@};
    return 0 if $arg =~ m{^name=};
    return 0 if $arg =~ m{^min_free=};
    return 1;
}

sub parse_options {
    my ($class, @args) = @_;

    my %out;
    my %file_vals;
    my $inline_threshold;
    my $inline_name;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        # Drop unknown k=>v pairs from the resource-group settings.
        if ($class->_is_unknown_kv_arg($arg, $i + 1 < @args)) {
            $out{$arg} = $args[$i + 1] if exists $OPTION_KEYS{$arg};
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
            my $parsed;
            eval { $parsed = parse_size_or_pct($1, name => 'min_free'); 1 }
                or croak "Resource::Memory: bad min_free in '$arg': $@";
            $inline_threshold = $parsed;
        }
        elsif ($arg =~ m{^[0-9]}) {
            # Bare-threshold shorthand: <pct%> or <size>.
            my $parsed;
            eval { $parsed = parse_size_or_pct($arg, name => 'min_free'); 1 }
                or croak "Resource::Memory: bad threshold '$arg': $@";
            $inline_threshold = $parsed;
        }
        else {
            croak "Resource::Memory: unrecognised entry '$arg'";
        }

        $i += 1;
    }

    # Precedence: file then inline.
    $out{min_free} = $file_vals{min_free} if exists $file_vals{min_free};
    $out{name}     = $file_vals{name}     if exists $file_vals{name};
    $out{min_free} = $inline_threshold    if defined $inline_threshold;
    $out{name}     = $inline_name         if defined $inline_name;

    $out{min_free} //= {kind => 'pct', value => 5};
    $out{name}     //= 'memory';

    return %out;
}

sub _load_config_file {
    my ($class, $path) = @_;

    croak "Resource::Memory config file '$path' does not exist" unless -e $path;
    open my $fh, '<:raw', $path or croak "Resource::Memory: cannot open '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    my $data;
    eval { $data = decode_json($body); 1 }
        or croak "Resource::Memory: cannot parse JSON in '$path': $@";
    croak "Resource::Memory: top-level of '$path' must be a JSON object"
        unless ref($data) eq 'HASH';

    my %allowed = map { $_ => 1 } qw/min_free name/;
    for my $k (sort keys %$data) {
        croak "Resource::Memory: unknown key '$k' in '$path'" unless $allowed{$k};
    }

    my %out;
    if (defined $data->{min_free}) {
        my $parsed;
        eval { $parsed = parse_size_or_pct($data->{min_free}, name => 'min_free'); 1 }
            or croak "Resource::Memory: bad min_free in '$path': $@";
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
            age         => hi_res_time() - $a->{assigned_at},
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

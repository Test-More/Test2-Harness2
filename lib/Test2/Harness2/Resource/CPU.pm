package Test2::Harness2::Resource::CPU;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Time::HiRes ();

use Test2::Harness2::Util::JSON qw/decode_json/;

use Object::HashBase qw{
    <assignments
    +utilize_percent
    +name
    +paused
    +prev_stat
    +last_busy_pct
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';
with 'Test2::Harness2::Role::Resource::Utilizer';

our $CLOCK = \&Time::HiRes::time;
sub _now { $CLOCK->() }

sub resource_name { $_[0]->{+NAME} // 'cpu' }

my %CTOR_KEYS = map { $_ => 1 } qw/utilize_percent name/;

sub parse_options {
    my ($class, @args) = @_;

    my %ctor;
    my %file_vals;
    my $inline_util;
    my $inline_name;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        if (   defined $arg
            && !ref($arg)
            && $arg !~ m{^[0-9]}
            && $arg !~ m{^@}
            && $arg !~ m{^name=}
            && $arg !~ m{^utilize=}
            && $i + 1 < @args)
        {
            $ctor{$arg} = $args[$i + 1] if exists $CTOR_KEYS{$arg};
            $i += 2;
            next;
        }

        croak "Resource::CPU: undef positional entry" unless defined $arg;
        croak "Resource::CPU: ref positional entry" if ref $arg;

        if ($arg =~ m{^\@(.+)\z}) {
            %file_vals = %{$class->_load_config_file($1)};
        }
        elsif ($arg =~ m{^name=(.*)\z}) {
            my $n = $1;
            croak "Resource::CPU: empty name=" unless defined $n && length $n;
            croak "Resource::CPU: name='$n' must be whitespace-free" if $n =~ /\s/;
            $inline_name = $n;
        }
        elsif ($arg =~ m{^utilize=([0-9]+(?:\.[0-9]+)?)\z}) {
            my $u = $1;
            croak "Resource::CPU: utilize must be > 0 and < 100 (got '$u')"
                unless $u > 0 && $u < 100;
            $inline_util = $u + 0;
        }
        elsif ($arg =~ m{^([0-9]+(?:\.[0-9]+)?)\z}) {
            my $u = $1;
            croak "Resource::CPU: utilize must be > 0 and < 100 (got '$u')"
                unless $u > 0 && $u < 100;
            $inline_util = $u + 0;
        }
        else {
            croak "Resource::CPU: unrecognised entry '$arg'";
        }

        $i += 1;
    }

    $ctor{utilize_percent} = $file_vals{utilize_percent} if exists $file_vals{utilize_percent};
    $ctor{name}            = $file_vals{name}            if exists $file_vals{name};
    $ctor{utilize_percent} = $inline_util                if defined $inline_util;
    $ctor{name}            = $inline_name                if defined $inline_name;

    $ctor{utilize_percent} //= 80;
    $ctor{name}            //= 'cpu';

    return %ctor;
}

sub _load_config_file {
    my ($class, $path) = @_;

    croak "Resource::CPU config file '$path' does not exist" unless -e $path;
    open my $fh, '<:raw', $path or croak "Resource::CPU: cannot open '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;

    my $data = eval { decode_json($body) };
    croak "Resource::CPU: cannot parse JSON in '$path': $@" if $@;
    croak "Resource::CPU: top-level must be a JSON object"
        unless ref($data) eq 'HASH';

    my %allowed = map { $_ => 1 } qw/utilize_percent name/;
    for my $k (sort keys %$data) {
        croak "Resource::CPU: unknown key '$k' in '$path'" unless $allowed{$k};
    }

    my %out;
    if (defined $data->{utilize_percent}) {
        my $u = $data->{utilize_percent};
        croak "Resource::CPU: utilize_percent in '$path' must be > 0 and < 100 (got '$u')"
            unless $u =~ m/^[0-9]+(?:\.[0-9]+)?\z/ && $u > 0 && $u < 100;
        $out{utilize_percent} = $u + 0;
    }
    if (defined $data->{name}) {
        my $n = $data->{name};
        croak "Resource::CPU: name in '$path' must be a non-empty whitespace-free string"
            unless !ref($n) && length($n) && $n !~ /\s/;
        $out{name} = $n;
    }

    return \%out;
}

sub init {
    my $self = shift;

    croak "Resource::CPU requires Linux (this is $^O)" unless $^O eq 'linux';

    $self->{+ASSIGNMENTS}   //= {};
    $self->{+NAME}          //= 'cpu';
    $self->{+LAST_BUSY_PCT} //= 0;

    my $u = $self->{+UTILIZE_PERCENT};
    croak "Resource::CPU: utilize_percent must be > 0 and < 100"
        unless defined $u && $u =~ m/^[0-9]+(?:\.[0-9]+)?\z/ && $u > 0 && $u < 100;
}

sub set_utilize_percent {
    my ($self, $pct) = @_;
    $self->{+UTILIZE_PERCENT} = $self->_validate_utilize_percent($pct);
    return;
}

# Test seam: tests override to inject deterministic /proc/stat rows.
sub _read_stat_first_line {
    open my $fh, '<', '/proc/stat' or die "open /proc/stat: $!";
    my $line = <$fh>;
    close $fh;
    return $line;
}

sub _sample {
    my $self = shift;

    my $line = $self->_read_stat_first_line;
    chomp $line;
    my @fields = split /\s+/, $line;
    shift @fields;    # 'cpu' label
                      # Fields after label: user nice system idle iowait irq softirq steal guest guest_nice
    croak "Resource::CPU: malformed /proc/stat line '$line'"
        unless @fields >= 5;

    my $idle  = $fields[3] + $fields[4];    # idle + iowait
    my $total = 0;
    $total += $_ for @fields;

    my $prev = $self->{+PREV_STAT};
    $self->{+PREV_STAT} = {total => $total, idle => $idle};

    return $self->{+LAST_BUSY_PCT} unless $prev;    # first call

    my $dt = $total - $prev->{total};
    my $di = $idle - $prev->{idle};

    return $self->{+LAST_BUSY_PCT} if $dt <= 0;     # divide-by-zero guard

    my $busy_pct = 100 * (1 - $di / $dt);
    $busy_pct = 0   if $busy_pct < 0;
    $busy_pct = 100 if $busy_pct > 100;

    $self->{+LAST_BUSY_PCT} = $busy_pct;
    return $busy_pct;
}

sub is_temporarily_unavailable {
    my $self = shift;
    my $busy = $self->_sample;
    return $busy >= $self->{+UTILIZE_PERCENT} ? 1 : 0;
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
    croak "Resource::CPU: duplicate assign for id '$id'"
        if exists $self->{+ASSIGNMENTS}->{$id};
    $self->{+ASSIGNMENTS}->{$id} = {job => $job, assigned_at => _now()};
    return 1;
}

sub release {
    my ($self, %p) = @_;
    my $id = $p{id} or croak "'id' is required";
    delete $self->{+ASSIGNMENTS}->{$id}
        or croak "Resource::CPU: invalid release id '$id'";
    return 1;
}

sub is_paused    { $_[0]->{+PAUSED} ? 1 : 0 }
sub mark_paused  { $_[0]->{+PAUSED} = 1 }
sub mark_resumed { $_[0]->{+PAUSED} = 0 }

sub status {
    my $self = shift;

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
        busy_pct          => $self->{+LAST_BUSY_PCT},
        paused            => $self->is_paused,
        total_assignments => scalar(keys %{$self->{+ASSIGNMENTS}}),
        assignments       => \@assignments,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::CPU - Throttle jobs against aggregate CPU usage.

=head1 SYNOPSIS

    yath -D test -j16 -R CPU                 # default utilize=80
    yath -D test -j16 -R CPU=70              # bare integer = utilize_percent
    yath -D test -j16 -R CPU=utilize=70      # explicit

=head1 DESCRIPTION

Defers new test starts when aggregate CPU usage (across every CPU and
core) is at or above C<utilize_percent>. Samples C</proc/stat>'s first
C<cpu> row at each call; computes percent from the delta against the
previous sample. The first call after construction stores the snapshot
and returns 0% (no delta yet); subsequent calls compute against that
prior snapshot and update it.

Multi-core scales automatically: the aggregate C<cpu> row sums jiffies
across every CPU, so C<--utilize 80> on an 8-core box means "defer
when ~6.4 cores worth of work is in flight".

=head1 LIMITATIONS

Linux only.

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

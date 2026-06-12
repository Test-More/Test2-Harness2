package Test2::Harness2::Resource::CPU;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;


use Object::HashBase qw{
    +prev_stat
    +last_busy_pct
    &Test2::Harness2::Role::Resource
    &Test2::Harness2::Role::Resource::Utilizer
};

sub inline_key_prefixes { [qw/utilize/] }

# Known keys; other resource-group settings are ignored.
my %OPTION_KEYS = map { $_ => 1 } qw/utilize_percent name/;

sub init {
    my $self = shift;

    croak "Resource::CPU requires Linux (this is $^O)" unless $^O eq 'linux';

    $self->{+LAST_BUSY_PCT} //= 0;

    my $u = $self->{+UTILIZE_PERCENT};
    croak "Resource::CPU: utilize_percent must be > 0 and < 100"
        unless defined $u && $u =~ m/^[0-9]+(?:\.[0-9]+)?\z/ && $u > 0 && $u < 100;
}

sub parse_options {
    my ($class, @args) = @_;

    my %out;
    my %file_vals;
    my $inline_util;
    my $inline_name;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        if ($class->is_unknown_kv_arg($arg, $i + 1 < @args)) {
            $out{$arg} = $args[$i + 1] if exists $OPTION_KEYS{$arg};
            $i += 2;
            next;
        }

        croak "Resource::CPU: undef positional entry" unless defined $arg;
        croak "Resource::CPU: ref positional entry" if ref $arg;

        if ($arg =~ m{^\@(.+)\z}) {
            %file_vals = %{$class->_load_config_file($1)};
        }
        elsif ($arg =~ m{^name=(.*)\z}) {
            $inline_name = $class->validate_name($1);
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

    $out{utilize_percent} = $file_vals{utilize_percent} if exists $file_vals{utilize_percent};
    $out{name}            = $file_vals{name}            if exists $file_vals{name};
    $out{utilize_percent} = $inline_util                if defined $inline_util;
    $out{name}            = $inline_name                if defined $inline_name;

    $out{utilize_percent} //= 80;
    $out{name}            //= 'cpu';

    return %out;
}

sub _load_config_file {
    my ($class, $path) = @_;

    my $data = $class->slurp_json_config($path);
    $class->whitelist_keys($data, [qw/utilize_percent name/], $path);

    my %out;
    if (defined $data->{utilize_percent}) {
        my $u = $data->{utilize_percent};
        croak "Resource::CPU: utilize_percent in '$path' must be > 0 and < 100 (got '$u')"
            unless $u =~ m/^[0-9]+(?:\.[0-9]+)?\z/ && $u > 0 && $u < 100;
        $out{utilize_percent} = $u + 0;
    }
    if (defined $data->{name}) {
        $out{name} = $class->validate_name($data->{name}, " in '$path'");
    }

    return \%out;
}

# Test seam.
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
                      # remaining: user nice system idle iowait irq softirq steal guest guest_nice
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

sub status {
    my $self = shift;
    return {
        resource        => $self->resource_name,
        utilize_percent => $self->{+UTILIZE_PERCENT},
        busy_pct        => $self->{+LAST_BUSY_PCT},
        paused          => $self->is_paused,
        in_flight       => $self->in_flight,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::CPU - Throttle jobs against aggregate CPU usage.

=head1 SYNOPSIS

    yath -D test -R CPU                 # default utilize=80
    yath -D test -R CPU=70              # bare integer = utilize_percent
    yath -D test -R CPU=utilize=70      # explicit

=head1 DESCRIPTION

Defers new test starts when aggregate CPU usage meets
C<utilize_percent>. Samples C</proc/stat>; multi-core systems are
handled by the aggregate jiffies in the first C<cpu> row.

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

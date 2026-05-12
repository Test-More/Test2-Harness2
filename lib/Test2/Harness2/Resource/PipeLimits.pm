package Test2::Harness2::Resource::PipeLimits;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Harness2::Util::Units qw/parse_count_or_pct/;
use Test2::Harness2::Util::HiResTime qw/hi_res_time/;

use Object::HashBase qw{
    <pipes_per_test
    <pipes_per_service
    <service_count
    <pages_per_pipe
    <cap_pages
    <headroom
    &Test2::Harness2::Role::Resource
    &Test2::Harness2::Role::Resource::Utilizer
};

sub inline_key_prefixes { [qw/pipes_per_test pipes_per_service service_count pages_per_pipe headroom/] }

my %OPTION_KEYS = map { $_ => 1 } qw/pipes_per_test pipes_per_service service_count pages_per_pipe headroom name utilize_percent/;

# Kernel sysctl defaults used when /proc/sys/fs/pipe-* is unreadable.
# Pulled from the Linux kernel headers (include/linux/pipe_fs_i.h):
# the per-user soft cap is "16 pages × N" where N is bigger than what
# CI runners care about; 16384 is the historical default of
# pipe-user-pages-soft, and pipe-max-size defaults to 1 MB which
# is 16 4 KiB pages of pipe ring buffer.
use constant DEFAULT_USER_PIPE_PAGES_SOFT => 16384;
use constant DEFAULT_PAGES_PER_PIPE       => 16;
use constant PAGE_SIZE_BYTES              => 4096;

sub init {
    my $self = shift;

    croak "Resource::PipeLimits requires Linux (this is $^O)" unless $^O eq 'linux';

    $self->{+ASSIGNMENTS} //= {};

    for my $k (qw/pipes_per_test pipes_per_service service_count/) {
        my $v = $self->{$k};
        croak "Resource::PipeLimits: $k must be a non-negative integer"
            unless defined $v && $v =~ m/^[0-9]+\z/;
    }

    $self->{+PAGES_PER_PIPE} //= $self->_read_pages_per_pipe;
    $self->{+CAP_PAGES}      //= $self->_read_cap_pages;

    my $h = $self->{+HEADROOM};
    croak "Resource::PipeLimits: headroom is required"
        unless ref($h) eq 'HASH'
        && defined $h->{kind}
        && ($h->{kind} eq 'count' || $h->{kind} eq 'pct')
        && defined $h->{value}
        && $h->{value} > 0;
}

sub parse_options {
    my ($class, @args) = @_;

    my %out;
    my %file_vals;
    my %inline;
    my $inline_name;

    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];

        if ($class->is_unknown_kv_arg($arg, $i + 1 < @args)) {
            $out{$arg} = $args[$i + 1] if exists $OPTION_KEYS{$arg};
            $i += 2;
            next;
        }

        croak "Resource::PipeLimits: undef positional entry" unless defined $arg;
        croak "Resource::PipeLimits: ref positional entry" if ref $arg;

        if ($arg =~ m{^\@(.+)\z}) {
            %file_vals = %{$class->_load_config_file($1)};
        }
        elsif ($arg =~ m{^name=(.*)\z}) {
            $inline_name = $class->validate_name($1);
        }
        elsif ($arg =~ m{^(pipes_per_test|pipes_per_service|service_count|pages_per_pipe)=([0-9]+)\z}) {
            $inline{$1} = $2 + 0;
        }
        elsif ($arg =~ m{^(pipes_per_test|pipes_per_service|service_count|pages_per_pipe)=(.+)\z}) {
            croak "Resource::PipeLimits: $1 must be a non-negative integer (got '$2')";
        }
        elsif ($arg =~ m{^headroom=(.+)\z}) {
            my $parsed;
            eval { $parsed = parse_count_or_pct($1, name => 'headroom'); 1 }
                or croak "Resource::PipeLimits: bad headroom in '$arg': $@";
            $inline{headroom} = $parsed;
        }
        elsif ($arg =~ m{^[0-9]}) {
            # Bare integer (count of pages) or pct.
            my $parsed;
            eval { $parsed = parse_count_or_pct($arg, name => 'headroom'); 1 }
                or croak "Resource::PipeLimits: bad bare threshold '$arg': $@";
            $inline{headroom} = $parsed;
        }
        else {
            croak "Resource::PipeLimits: unrecognised entry '$arg'";
        }

        $i += 1;
    }

    for my $k (qw/pipes_per_test pipes_per_service service_count pages_per_pipe headroom name/) {
        $out{$k} = $file_vals{$k} if exists $file_vals{$k};
    }
    for my $k (qw/pipes_per_test pipes_per_service service_count pages_per_pipe headroom/) {
        $out{$k} = $inline{$k} if exists $inline{$k};
    }
    $out{name} = $inline_name if defined $inline_name;

    $out{pipes_per_test}    //= 2;
    $out{pipes_per_service} //= 2;
    $out{service_count}     //= 0;
    # pages_per_pipe filled in by init from /proc if not supplied.
    $out{headroom} //= {kind => 'pct', value => 10};
    $out{name}     //= 'pipelimits';

    return %out;
}

sub _load_config_file {
    my ($class, $path) = @_;

    my $data = $class->slurp_json_config($path);
    $class->whitelist_keys(
        $data,
        [qw/pipes_per_test pipes_per_service service_count pages_per_pipe headroom name/],
        $path,
    );

    my %out;
    for my $k (qw/pipes_per_test pipes_per_service service_count pages_per_pipe/) {
        next unless defined $data->{$k};
        croak "Resource::PipeLimits: $k in '$path' must be a non-negative integer"
            unless $data->{$k} =~ m/^[0-9]+\z/;
        $out{$k} = $data->{$k} + 0;
    }
    if (defined $data->{headroom}) {
        my $parsed;
        my $ok  = eval { $parsed = parse_count_or_pct($data->{headroom}, name => 'headroom'); 1 };
        my $err = $@;
        croak "Resource::PipeLimits: bad headroom in '$path': $err" unless $ok;
        $out{headroom} = $parsed;
    }
    if (defined $data->{name}) {
        $out{name} = $class->validate_name($data->{name}, " in '$path'");
    }
    return \%out;
}

# Test seam: override to inject /proc/sys/fs/pipe-user-pages-soft value.
sub _read_cap_pages {
    my $path = '/proc/sys/fs/pipe-user-pages-soft';
    return DEFAULT_USER_PIPE_PAGES_SOFT unless -r $path;
    open my $fh, '<', $path or return DEFAULT_USER_PIPE_PAGES_SOFT;
    my $line = <$fh>;
    close $fh;
    return ($line && $line =~ m/^([0-9]+)/) ? ($1 + 0) : DEFAULT_USER_PIPE_PAGES_SOFT;
}

# Test seam: override to inject /proc/sys/fs/pipe-max-size value.
sub _read_pages_per_pipe {
    my $path = '/proc/sys/fs/pipe-max-size';
    return DEFAULT_PAGES_PER_PIPE unless -r $path;
    open my $fh, '<', $path or return DEFAULT_PAGES_PER_PIPE;
    my $line = <$fh>;
    close $fh;
    return DEFAULT_PAGES_PER_PIPE unless $line && $line =~ m/^([0-9]+)/;
    my $bytes = $1 + 0;
    my $pages = int($bytes / PAGE_SIZE_BYTES);
    return $pages > 0 ? $pages : DEFAULT_PAGES_PER_PIPE;
}

sub _effective_min_free_pages {
    my $self = shift;
    my $cap  = $self->{+CAP_PAGES};

    my $h = $self->{+HEADROOM};
    my $explicit =
          $h->{kind} eq 'count'
        ? $h->{value}
        : int($cap * $h->{value} / 100);

    my $utilize = 0;
    if (defined $self->{+UTILIZE_PERCENT}) {
        $utilize = int($cap * (100 - $self->{+UTILIZE_PERCENT}) / 100);
    }

    return $explicit > $utilize ? $explicit : $utilize;
}

sub _usage_pages {
    my $self          = shift;
    my $service_pages = $self->{+SERVICE_COUNT} * $self->{+PIPES_PER_SERVICE} * $self->{+PAGES_PER_PIPE};
    my $in_flight     = scalar keys %{$self->{+ASSIGNMENTS}};
    my $test_pages    = $in_flight * $self->{+PIPES_PER_TEST} * $self->{+PAGES_PER_PIPE};
    return ($service_pages, $test_pages);
}

sub is_temporarily_unavailable {
    my $self = shift;
    my ($svc, $tst) = $self->_usage_pages;
    my $free = $self->{+CAP_PAGES} - $svc - $tst;
    my $next = $self->{+PIPES_PER_TEST} * $self->{+PAGES_PER_PIPE};
    my $thr  = $self->_effective_min_free_pages;
    return ($free - $next) < $thr ? 1 : 0;
}

sub available {
    my ($self, %p) = @_;
    croak "'job' is required" unless defined $p{job};
    return 1;
}

sub status {
    my $self = shift;
    my ($svc, $tst) = $self->_usage_pages;
    my $free = $self->{+CAP_PAGES} - $svc - $tst;
    my $thr  = $self->_effective_min_free_pages;

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
        utilize_percent          => $self->{+UTILIZE_PERCENT},
        paused                   => $self->is_paused,
        cap_pages                => $self->{+CAP_PAGES},
        pages_per_pipe           => $self->{+PAGES_PER_PIPE},
        pipes_per_test           => $self->{+PIPES_PER_TEST},
        pipes_per_service        => $self->{+PIPES_PER_SERVICE},
        service_count            => $self->{+SERVICE_COUNT},
        service_pages            => $svc,
        test_pages               => $tst,
        free_pages               => $free,
        headroom                 => $self->{+HEADROOM},
        effective_min_free_pages => $thr,
        total_assignments        => scalar(keys %{$self->{+ASSIGNMENTS}}),
        assignments              => \@assignments,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::PipeLimits - Throttle jobs when per-user pipe budget is close to exhausted.

=head1 SYNOPSIS

    yath -D test -R PipeLimits
    yath -D test -R PipeLimits=10%
    yath -D test -R PipeLimits=service_count=5,headroom=15%

=head1 DESCRIPTION

The Linux per-user pipe page budget
(C</proc/sys/fs/pipe-user-pages-soft>) caps how many memory pages
across all pipes one user may hold open. Exceeding it makes new
C<pipe(2)> calls fail.

PipeLimits maintains a tally derived from the harness's
C<assign>/C<release> contract (each test pair consumes
C<pipes_per_test> pipes; the harness's own services consume a
configured C<service_count * pipes_per_service> baseline) and defers
new test starts when the next test would push usage past the
configured headroom. No C</proc> walking; the tally is internal.

C<headroom> may be expressed as a count of pages or as a percent of
the cap. C<--utilize PCT> layers on top; effective threshold is the
more conservative of the two.

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

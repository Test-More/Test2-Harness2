package App::Yath2::Command::resources;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/sleep/;

use Test2::Harness2::Spawn;
use App::Yath2::Util::IPC qw/discover_daemons assert_daemon_alive/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

use Object::HashBase qw{
    <args
    <settings
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Harness',
    'App::Yath2::Options::IPC',
);

option_group {group => 'resources', category => "Resources Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to query.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, pick the most recently started.',
    );

    option watch => (
        type        => 'Bool',
        default     => 0,
        description => 'Repeatedly redraw the resource list. Exit on SIGINT.',
    );

    option interval => (
        type          => 'Scalar',
        default       => 1,
        long_examples => [' SECS'],
        description   => 'Seconds between refreshes when --watch is set.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "List active resource services on a running yath daemon" }

sub description {
    return <<"    EOT";
Print the active resource services (JobCount, CPU limits, preloads,
custom resources) on a running yath daemon. Use --watch to refresh
the view continuously.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;

    my $settings = $self->{+SETTINGS};
    my $opts     = $settings->resources;

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $opts->workdir,
        latest   => $opts->latest,
    );
    assert_daemon_alive($info);

    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $info->{pid},
        ipcm_info            => $info->{ipcm_info},
        workdir              => $info->{workdir},
        terminate_on_destroy => 0,
    );

    my $sig = 0;
    local $SIG{INT} = sub { $sig++ };

    my $first = 1;
    while (!$sig) {
        my $st;
        my $ok = eval { $st = $spawn->status; 1 };
        my $err = $@;
        unless ($ok) {
            chomp $err;
            print STDERR "resources: $err\n";
            return 1;
        }

        if ($opts->watch && !$first) {
            print "\e[2J\e[1;1H";    # clear screen + home cursor
        }
        $first = 0;

        $self->_render($st);

        last unless $opts->watch;
        sleep($opts->interval // 1);
    }

    return 0;
}

sub _render {
    my ($self, $st) = @_;
    my $rsrc = $st->{resources} // [];
    printf("Resources: %d\n", scalar @$rsrc);
    for my $r (@$rsrc) {
        if (ref($r) eq 'HASH') {
            my $name = $r->{resource} // $r->{name} // '?';
            my @keys = grep { $_ ne 'resource' && $_ ne 'name' && $_ ne 'assignments' } sort keys %$r;
            my $detail = join ' ', map {
                my $v = $r->{$_};
                "$_=" . (ref($v) ? ref($v) : (defined $v ? $v : ''));
            } @keys;
            print "  $name" . ($detail ? "  $detail" : '') . "\n";
        }
        else {
            print "  ", (defined $r ? $r : '?'), "\n";
        }
    }

    my $services = $st->{services} // [];
    if (@$services) {
        printf("\nServices: %d\n", scalar @$services);
        for my $s (@$services) {
            printf("  %s (%s) pid=%s scope=%s via_preload=%s\n",
                ($s->{name}          // '?'),
                ($s->{service_class} // '?'),
                ($s->{pid}           // '?'),
                ($s->{scope}         // '?'),
                ($s->{via_preload} ? 'yes' : 'no'),
            );
        }
    }
}

1;

__END__

=head1 POD IS AUTO-GENERATED

=cut

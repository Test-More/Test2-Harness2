package App::Yath2::Command::watch;
use strict;
use warnings;

our $VERSION = '2.000011';

use Time::HiRes qw/sleep/;

# XXX TODO: App::Yath2::Client depends on removed IPC layer (PR #390)

use Test2::Harness2::Util::IPC qw/pid_is_running set_procname/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase qw{
    +client
    +renderers
    <args
    <settings
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Renderer',
);

sub args_include_tests { 0 }

sub load_renderers { 1 }

sub group { 'daemon' }

sub summary { "Watch/Tail a test runner" }

sub description {
    return <<"    EOT";
Tails the log from a running yath daemon
    EOT
}

sub process_name { "watcher" }

sub client {
    # XXX TODO: App::Yath2::Client removed (PR #390); reimplment once IPC layer is restored
    die "App::Yath2::Client has been removed (PR #390)\n";
}

sub renderers {
    my $self = shift;

    return $self->{+RENDERERS} if $self->{+RENDERERS};

    my $settings = $self->settings;

    my $verbose = 2;
    $verbose = 0 if $settings->renderer->quiet;
    return $self->{+RENDERERS} //= App::Yath2::Options::Renderer->init_renderers($settings, verbose => $verbose, progress => 0);
}

sub run {
    my $self = shift;

    set_procname(
        set => [$self->process_name],
        prefix => $self->{+SETTINGS}->harness->procname_prefix,
    );

    return $self->render_log();
}

sub render_log {
    my $self = shift;
    my ($cb) = @_;

    my $renderers = $self->renderers;
    my $client    = $self->client;
    my $pid       = $client->send_and_get('pid');

    my $sig = 0;
    $SIG{INT} = sub { $sig++ };

    while (!$sig && pid_is_running($pid)) {
        $cb->() if $cb;

        # XXX TODO Need to hook in the events we used to poll for here somewhere else I think?

        last if $self->{+ARGS} && grep { m/STOP/i } @{$self->{+ARGS}};
        sleep(0.2);
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED


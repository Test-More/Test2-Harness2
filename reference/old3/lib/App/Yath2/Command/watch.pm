package App::Yath2::Command::watch;
use strict;
use warnings;

our $VERSION = '2.000013';

use App::Yath2::Util::IPC qw/discover_daemons assert_daemon_alive/;
use Test2::Harness2::Util::IPC qw/set_procname/;

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
    'App::Yath2::Options::Renderer',
);

option_group {group => 'watch', category => "Watch Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to tail.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, tail the most recently started.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 1 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Tail a running yath daemon's event log" }

sub description {
    return <<"    EOT";
Live-tail a running yath daemon's global event log via the standard
yath renderer. Run/test-specific event sub-logs are not opened in this
mode; use --renderer / --quiet for the usual rendering controls.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;

    set_procname(
        set    => ['watcher'],
        prefix => $self->{+SETTINGS}->harness->procname_prefix,
    );

    my $settings = $self->{+SETTINGS};
    my $opts     = $settings->watch;

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $opts->workdir,
        latest   => $opts->latest,
    );
    assert_daemon_alive($info);

    require App::Yath2::Renderer::Driver;

    my $exit = App::Yath2::Renderer::Driver->run(
        logdir      => "$info->{workdir}/logs",
        settings    => $settings,
        harness_pid => $info->{pid},
    );

    return $exit // 0;
}

1;

__END__

=head1 METHODS

=head2 load_plugins / load_resources / accepts_dot_args

Standard Command framework hooks (see L<App::Yath2::Role::Command>). Plugins,
resources, and dot-args are all off; watch overrides C<load_renderers> to true
because it drives L<App::Yath2::Renderer::Driver> against the daemon's log.

=head1 POD IS AUTO-GENERATED

=cut

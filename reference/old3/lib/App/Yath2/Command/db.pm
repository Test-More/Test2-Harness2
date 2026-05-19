package App::Yath2::Command::db;
use strict;
use warnings;

our $VERSION = '2.000013';

use App::Yath2UI::Server;
use App::Yath2UI::Schema::Util qw/schema_config_from_settings/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase;

sub summary     { "Start a yath2-UI server (with optional ephemeral database)" }
sub description { "Starts a yath2-UI server with an embedded ephemeral database for temporary data storage. Data is deleted when the server shuts down." }
sub group       { "database" }

sub cli_args { "" }

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::DB',
    'App::Yath2::Options::Server',
);

sub run {
    my $self = shift;

    my $args = $self->args;
    my $settings = $self->settings;

    my $daemon = $settings->server->daemon;

    if ($daemon) {
        my $pid = fork // die "Could not fork";
        exit(0) if $pid;

        POSIX::setsid();
        setpgrp(0, 0);

        $pid = fork // die "Could not fork";
        exit(0) if $pid;
    }

    my $ephemeral = $settings->server->ephemeral;
    unless($ephemeral) {
        $ephemeral = 'Auto';
        $settings->server->ephemeral($ephemeral);
    }

    my $config = schema_config_from_settings($settings, ephemeral => $ephemeral);

    my $qdb_params = {
        single_user => $settings->server->single_user // 0,
        single_run  => $settings->server->single_run  // 0,
        no_upload   => $settings->server->no_upload   // 0,
        email       => $settings->server->email       // undef,
    };

    my $server = App::Yath2UI::Server->new(schema_config => $config, qdb_params => $qdb_params);
    $server->start_ephemeral_db;

    my $dsn = $config->dbi_dsn;

    print "\nDBI_DSN: $dsn\n";

    my $done = 0;
    $SIG{TERM} = sub { $done++; print "Caught SIGTERM shutting down...\n" unless $daemon; $SIG{TERM} = 'DEFAULT' };
    $SIG{INT}  = sub { $done++; print "Caught SIGINT shutting down...\n"  unless $daemon; $SIG{INT}  = 'DEFAULT' };

    if ($settings->server->shell) {
        print "\n";
        local $ENV{YATH_SHELL} = 1;
        system($ENV{SHELL});
    }
    else {
        $server->qdb->watcher->detach if $daemon;
        sleep 1 until $done;
    }

    $server->stop_ephemeral_db if $server->qdb;

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED


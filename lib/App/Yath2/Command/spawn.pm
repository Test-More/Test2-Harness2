package App::Yath2::Command::spawn;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/sleep time/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase qw{
    <args
    <settings
};

sub group { 'daemon' }

sub summary { "Launch a perl script from the preloaded environment" }
sub cli_args { "[--] path/to/script.pl [options and args]" }

sub description {
    return <<"    EOT";
This will launch the specified script from the preloaded yath process.

NOTE: environment variables are not automatically passed to the spawned
process. You must use -e or -E (see help) to specify what environment variables
you care about.
    EOT
}

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

use Getopt::Yath;
option_group {group => 'spawn', category => 'spawn options'} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to spawn from. Without --workdir / --ipc-file, the running daemon is auto-discovered.',
    );

    option stage => (
        short => 's',
        type => 'Scalar',
        description => 'Specify the stage to be used for launching the script',
        long_examples => [ ' foo'],
        short_examples => [ ' foo'],
    );

    option copy_env => (
        short => 'e',
        type => 'List',
        description => "Specify environment variables to pass along with their current values, can also use a regex",
        long_examples => [ ' HOME', ' SHELL', ' /PERL_.*/i' ],
        short_examples => [ ' HOME', ' SHELL', ' /PERL_.*/i' ],
    );

    option env_var => (
        field          => 'env_vars',
        short          => 'E',
        type           => 'Map',
        long_examples  => [' VAR=VAL'],
        short_examples => ['VAR=VAL', ' VAR=VAL'],
        description    => 'Set environment variables for the spawn',
    );
};

include_options(
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Yath',
);

sub run {
    my $self = shift;
    my $settings = $self->{+SETTINGS};

    require App::Yath2::Util::IPC;
    my $info = App::Yath2::Util::IPC::discover_daemons(
        settings => $settings,
        ($settings->ipc->file ? (ipc_file => $settings->ipc->file) : ()),
        ($settings->spawn->workdir ? (workdir => $settings->spawn->workdir) : ()),
    );
    App::Yath2::Util::IPC::assert_daemon_alive($info);

    require Test2::Harness2::Spawn;
    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $info->{pid},
        ipcm_info            => $info->{ipcm_info},
        workdir              => $info->{workdir},
        terminate_on_destroy => 0,
        listen               => 1,
    );

    # Resolve script path + cwd.
    my $args = [@{$self->{+ARGS} // []}];
    my $script = shift @$args;
    die "yath spawn: no script given\n"
        unless defined $script && length $script;
    die "yath spawn: script not readable: $script\n"
        unless -r $script;
    require Cwd;
    my $script_abs = Cwd::abs_path($script);

    my $stage = $settings->spawn->stage;
    unless (defined $stage && length $stage) {
        my $st = $spawn->status;
        my @preloads =
            grep { ($_->{service_class} // '') eq 'Test2::Harness2::PreloadService'
                && ($_->{scope}         // '') eq 'global'
                && !$_->{via_preload} }
            @{ $st->{services} // [] };
        if (@preloads == 0) {
            die "yath spawn: no preload stages running; start one with `yath start -P MODULE`\n";
        }
        elsif (@preloads > 1) {
            my $list = join ", ", map { $_->{name} // '?' } @preloads;
            die "yath spawn: multiple preload stages running ($list); pass -s STAGE to choose\n";
        }
        # Derive bare stage name from 'preload-FOO' bus name.
        ($stage) = ($preloads[0]{name} // '') =~ m{\Apreload-(.+)\z};
        die "yath spawn: cannot derive stage name from '$preloads[0]{name}'\n"
            unless defined $stage && length $stage;
    }

    require App::Yath2::Spawn::Client;
    my $exit = App::Yath2::Spawn::Client::run_spawn(
        spawn  => $spawn,
        stage  => $stage,
        script => $script_abs,
        argv   => $args,
        env    => $self->env,
        cwd    => Cwd::getcwd(),
    );

    return $exit;
}

sub env {
    my $self = shift;

    my $settings = $self->settings;

    my %env;

    for my $var (@{$settings->spawn->copy_env // []}) {
        $env{$var} = $ENV{$var} if exists $ENV{$var};
    }

    if (my $set = $settings->spawn->env_vars) {
        $env{$_} = $set->{$_} for keys %$set;
    }

    return \%env;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::spawn - Run a perl script in a yath daemon's preloaded environment

=head1 SYNOPSIS

    # Start a daemon with one or more preload stages.
    yath start -P MyApp::Boot -P MyApp::Slow

    # Run a script under the named stage:
    yath spawn -s BASE -- path/to/script.pl arg1 arg2

    # When only one stage is running, -s can be omitted:
    yath spawn -- path/to/script.pl

=head1 DESCRIPTION

Forwards the script to the daemon's matching PreloadService, which forks
a grandchild with the preloaded modules still in C<%INC>. STDIN, STDOUT,
and STDERR are passed to the grandchild via SCM_RIGHTS so the script
runs against the user's real terminal (TTY semantics, line editing,
SIGWINCH, etc all work). Exit status is forwarded back.

C<yath spawn> requires the daemon to be running with the
C<IPC::Manager::Client::ConnectionUnix> transport (the default). Other
transports cannot carry SCM_RIGHTS and will be rejected with a clear
error.

=head1 OPTIONS

See C<--help> for the full list. The notable ones:

=over 4

=item -s, --stage NAME

Which preload stage to run under. Optional when exactly one stage is
running.

=item -e VAR

Copy C<$ENV{VAR}> from the calling process into the spawned script's
environment.

=item -E VAR=VALUE

Set an explicit env var in the spawned script.

=back

=cut

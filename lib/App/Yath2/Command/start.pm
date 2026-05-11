package App::Yath2::Command::start;
use strict;
use warnings;

our $VERSION = '2.000013';

use POSIX ();
use Time::HiRes qw/sleep time/;

use Scope::Guard ();

use Test2::Harness2;
use Test2::Harness2::Util qw/mod2file/;
use Test2::Harness2::Util::IPC qw/set_procname/;

use App::Yath2::Util::IPC qw/publish_ipc_file unlink_ipc_file/;

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
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Preload',
    'App::Yath2::Options::Resource',
    'App::Yath2::Options::Runner',
    'App::Yath2::Options::Tests',
);

option_group {group => 'start', category => "Start Options"} => sub {
    option foreground => (
        short       => 'f',
        alt         => ['no-daemon'],
        alt_no      => ['daemon'],
        type        => 'Bool',
        default     => 0,
        description => "Keep yath in the foreground instead of daemonizing and returning you to the shell.",
    );
};

sub load_plugins   { 1 }
sub load_resources { 1 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Start a test runner daemon" }

sub description {
    return <<"    EOT";
Start a yath harness that stays up after each test run finishes. Other
yath commands (notably `yath run`) connect to the daemon via the IPC
info file it publishes, so successive runs reuse the same harness
process -- including any preload services it brought up at startup.

By default the command daemonizes and returns once the harness is
ready. Pass --foreground (-f) to keep the harness attached to the
current terminal.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};

    die "yath start takes no positional arguments; got: @{$self->{+ARGS}}\n"
        if $self->{+ARGS} && @{$self->{+ARGS}};

    my $workdir = $settings->workspace->workdir;

    # Build + fork the harness. Spawning fires its global resource
    # services (Resource::Preload included) and blocks until the
    # service is ready to accept requests, so a startup failure
    # surfaces here -- before we daemonize -- and the user sees the
    # diagnostic on the terminal they invoked us from.
    my $spawn = $self->_spawn_harness($workdir);

    # The Spawn handle's DESTROY sends a terminate to the harness;
    # clear that ownership before any planned detachment so a normal
    # parent exit doesn't take the daemon down with it.
    my $detach_spawn = sub {
        my $ok = eval { $spawn->clear_terminate_on_destroy; 1 };
        warn "clear_terminate_on_destroy: $@" unless $ok;
    };

    my $info_path;
    my $writer_pid = $$;
    my $cleanup_ipc = sub {
        unlink_ipc_file($info_path, $writer_pid) if defined $info_path;
    };

    my $start_ok = eval {
        $info_path = publish_ipc_file(
            command  => 'start',
            settings => $settings,
            spawn    => $spawn,
            workdir  => $workdir,
        );
        1;
    };
    unless ($start_ok) {
        my $err = $@;
        # Best-effort teardown of the harness we just spawned.
        eval { $spawn->terminate; 1 };
        eval { $spawn->wait;      1 };
        die "Failed to publish IPC info file: $err";
    }

    if ($settings->start->foreground) {
        # Foreground mode: stay attached, install signal handlers,
        # wait for the harness to exit (whether through a signal we
        # forward, or its own teardown).
        $self->_run_foreground($spawn, $info_path, $cleanup_ipc);
        return 0;
    }

    # Daemon mode: print the breadcrumb on the terminal, then
    # detach. The harness service (our child via fork+exec / fork)
    # is already running; we just need to step out of the way
    # without taking it down.
    print "started: pid=" . $spawn->pid . " workdir=$workdir ipc=$info_path\n";

    # Detach: tell the harness to drop our pid from its watch_pids
    # (so our exit does not trigger its shutdown), clear our local
    # Spawn destructor's terminate hook, fork off a tiny watchdog
    # to clean up the IPC info file when the daemon eventually goes
    # away, then _exit so Perl's normal teardown does not unwind
    # scope guards from IPC::Manager / Workspace that would tear
    # the daemon's workdir contents down with us.
    # Watchdog fork before clearing the destroy hook so an early
    # crash here still cleans up the IPC info file once the daemon
    # eventually exits.
    $self->_spawn_ipc_watchdog($spawn->pid, $info_path);

    # Clear the Spawn handle's destructor + skip Perl-level cleanup
    # via POSIX::_exit. Otherwise IPC::Manager's bus post_disconnect
    # hook + any inherited Scope::Guard destructors would recurse
    # into the workdir we just handed off to the daemon.
    $detach_spawn->();

    STDOUT->flush;
    STDERR->flush;
    POSIX::_exit(0);
}

sub _spawn_harness {
    my ($self, $workdir) = @_;
    my $settings = $self->{+SETTINGS};

    my @resources = $self->_build_resources;

    # watch_pids => [] tells the daemon not to tie its lifecycle to
    # any caller process: yath start exits as soon as the daemon is
    # up, and the daemon stays alive until something else (a TERM,
    # `yath stop`, etc.) takes it down. The default behaviour --
    # watch the caller pid and exit when it goes away -- is what
    # `yath test` wants but the exact opposite of what we want here.
    return Test2::Harness2->spawn(
        workdir     => $workdir,
        protocol    => $settings->ipc->protocol,
        resources   => \@resources,
        watch_pids  => [],
    );
}

# Same shape as App::Yath2::Command::test::_build_resources: turn
# Options::Resource's classes into instances, append a
# Resource::Preload built from any -P / --preload modules.
sub _build_resources {
    my $self = shift;
    my $rg   = $self->{+SETTINGS}->resource;

    my @out;

    my $classes = $rg->classes // {};
    if (keys %$classes) {
        for my $mod (sort keys %$classes) {
            require(mod2file($mod));
            my @args = @{$classes->{$mod} // []};

            if ($mod eq 'Test2::Harness2::Resource::JobCount' && !@args) {
                push @out => $mod->new(
                    slots       => $rg->slots,
                    max_per_job => $rg->job_slots,
                );
                next;
            }

            my @ctor_args =
                  $mod->can('parse_options')
                ? $mod->parse_options(@args)
                : @args;
            push @out => $mod->new(@ctor_args);
        }
    }

    my $settings = $self->{+SETTINGS};
    my $preload  = eval { $settings->preload };
    my $modules  = $preload && eval { $preload->check_option('modules') } ? $preload->modules : undef;
    if ($modules && @$modules) {
        require Test2::Harness2::Resource::Preload;
        require App::Yath2::Options::Preload;
        for my $group (App::Yath2::Options::Preload::classify_preload_modules($modules)) {
            push @out => Test2::Harness2::Resource::Preload->new(%$group);
        }
    }

    return @out;
}

# Foreground: forward INT/TERM/HUP to the harness, then wait for it
# to exit. unlink the IPC info file regardless of how we leave.
sub _run_foreground {
    my ($self, $spawn, $info_path, $cleanup) = @_;

    set_procname(
        set    => ['daemon', 'foreground'],
        prefix => $self->{+SETTINGS}->harness->procname_prefix,
    );

    my $harness_pid = $spawn->pid;
    print "started: pid=$harness_pid workdir=" . $self->{+SETTINGS}->workspace->workdir
        . " ipc=$info_path\n";

    my $terminated = 0;
    for my $sig (qw/INT TERM HUP/) {
        $SIG{$sig} = sub {
            return if $terminated++;
            print STDERR "Caught SIG$sig, asking harness $harness_pid to shut down...\n";
            eval { $spawn->terminate; 1 } or warn "spawn->terminate: $@";
        };
    }

    my $ok  = eval { $spawn->wait; 1 };
    my $err = $@;
    $cleanup->();
    die "spawn->wait failed: $err" unless $ok;
    return;
}

# Spawn a tiny watchdog child that waits for the harness pid to
# disappear and then unlinks the published IPC file. Independent of
# the parent process so it survives `yath start`'s exit; doesn't
# hold a Spawn handle so it can't accidentally terminate the daemon
# on its own DESTROY.
sub _spawn_ipc_watchdog {
    my ($self, $harness_pid, $info_path) = @_;

    my $pid = fork;
    die "fork (ipc watchdog): $!" unless defined $pid;

    return if $pid;    # parent: caller exits below

    # Child: detach from controlling terminal + process group, drop
    # any inherited stdio, set procname, then sit watching the
    # harness pid via kill 0.
    require POSIX;
    POSIX::setsid();

    open(STDIN,  '<', '/dev/null');
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');

    set_procname(
        set    => ['daemon', 'ipc-watchdog'],
        prefix => $self->{+SETTINGS}->harness->procname_prefix,
    );

    # Poll. kill(0, $pid) returns true while the process exists; a
    # 0.5s tick is fine -- the watchdog is just cleaning up an info
    # file, no liveness expectation.
    while (kill 0 => $harness_pid) {
        sleep(0.5);
    }

    unlink_ipc_file($info_path) if defined $info_path && -e $info_path;
    POSIX::_exit(0);
}

1;

__END__

=head1 POD IS AUTO-GENERATED

=cut

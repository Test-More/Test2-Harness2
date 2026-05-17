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
    'App::Yath2::Options::Reloader',
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
    # services (Resource::Preload included) and blocks until ready,
    # so a startup failure surfaces here -- before we daemonize -- so
    # the user sees the diagnostic on their invoking terminal.
    my $spawn = $self->_spawn_harness($workdir);

    my $writer_pid = $$;
    my $info_path  = $self->_publish_ipc_or_die($settings, $spawn, $workdir);
    my $cleanup_ipc = sub {
        unlink_ipc_file($info_path, $writer_pid) if defined $info_path;
    };

    if ($settings->start->foreground) {
        # Foreground: stay attached, forward signals, wait for the
        # harness to exit (either through a signal we forwarded or
        # its own teardown).
        $self->_run_foreground($spawn, $info_path, $cleanup_ipc);
        return 0;
    }

    $self->_detach_into_daemon($spawn, $info_path, $workdir);
    return 0;    # unreachable: _detach_into_daemon POSIX::_exits
}

sub _publish_ipc_or_die {
    my ($self, $settings, $spawn, $workdir) = @_;

    my $info_path;
    my $ok = eval {
        $info_path = publish_ipc_file(
            command  => 'start',
            settings => $settings,
            spawn    => $spawn,
            workdir  => $workdir,
        );
        1;
    };
    return $info_path if $ok;

    my $err = $@;
    eval { $spawn->terminate; 1 };    # best-effort teardown of the just-spawned harness
    eval { $spawn->wait;      1 };
    die "Failed to publish IPC info file: $err";
}

# Daemon-mode: print the breadcrumb, hand the daemon off, then
# _exit() so Perl's teardown does not unwind scope guards
# (IPC::Manager bus post_disconnect, Workspace, inherited
# Scope::Guard destructors) that would tear down workdir contents
# we just handed to the daemon. Watchdog forks *before* clearing
# the Spawn destroy hook so a crash here still cleans the IPC info
# file when the daemon eventually exits.
sub _detach_into_daemon {
    my ($self, $spawn, $info_path, $workdir) = @_;

    print "started: pid=" . $spawn->pid . " workdir=$workdir ipc=$info_path\n";

    $self->_spawn_ipc_watchdog($spawn->pid, $info_path);

    my $ok = eval { $spawn->clear_terminate_on_destroy; 1 };
    warn "clear_terminate_on_destroy: $@" unless $ok;

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

    require App::Yath2::Preload;
    for my $args (App::Yath2::Preload::preload_resource_args(settings => $self->{+SETTINGS})) {
        require Test2::Harness2::Resource::Preload;
        push @out => Test2::Harness2::Resource::Preload->new(%$args);
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

=head1 METHODS

=head2 _publish_ipc_or_die

Publish the IPC info file via L<App::Yath2::Util::IPC/publish_ipc_file>. On
failure, terminate and reap the just-spawned harness before rethrowing so we
do not orphan it.

=head2 _detach_into_daemon

Print the startup breadcrumb, fork the IPC watchdog, clear the Spawn destroy
hook, and C<POSIX::_exit> so Perl teardown does not unwind scope guards that
own workdir contents now belonging to the daemon.

=head2 _spawn_harness

Build the resource list and fork the harness via L<Test2::Harness2/spawn> with
C<watch_pids =E<gt> []> so the daemon outlives its parent.

=head2 _build_resources

Instantiate the resource classes from C<--resource> options and append a
L<Test2::Harness2::Resource::Preload> for each C<-P> / C<--preload> module.

=head2 _run_foreground

Stay attached: forward INT/TERM/HUP to the harness, wait for it to exit, then
unlink the published IPC info file regardless of how we leave.

=head2 _spawn_ipc_watchdog

Fork a detached child that polls the harness pid and unlinks the IPC info
file once the harness exits, so the breadcrumb does not outlive its daemon.

=head1 POD IS AUTO-GENERATED

=cut

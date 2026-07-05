package Test2::Harness2::Preload;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX();
use Long::Jump qw/setjump/;
use Time::HiRes qw/sleep/;
use File::Spec();

use Test2::Harness2::Util qw/mono_time/;

use Test2::Harness2::Util::HashBase qw{
    <runner_socket
    <workdir
    +responses
    +stopped
    +runner_pid
    +monitor_preloads
    +my_pid
    +warnings
    +settings
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preload - The preload-root bootstrap process.

=head1 DESCRIPTION

This module is the C<-M> bootstrap target for the B<preload root> process the
runner spawns when a run uses preloads. The preload root hosts the preload
stages so the runner itself holds no preloaded interpreter state. The runner
forks+execs a clean perl:

    $^X -I... -MTest2::Harness2::Preload=launch,/path/to/runner.socket -e '1;'

Loading this module with the C<launch> argument runs its bootstrap in C<BEGIN>
(compile phase): it establishes the L<Long::Jump> host frame future test
launches unwind to (so a preloaded test forks with no added stack frame -- that
launch path lands in a later chunk), dials the runner over C<runner.socket>,
asks the runner for the preload list, loads those preload libraries, reports the
stage map back to the runner, and then services its channel until the runner
tells it to stop.

It B<is> the compile-time host that used to live inside the runner: moving it
here keeps the runner a pure orchestrator that holds no preloaded interpreter
state.

This is B<not> L<Test2::Harness2::Runner::Preload> (the user-facing preload DSL /
stage-tree meta object); this is the process bootstrap, which consumes that
meta.

=head1 SYNOPSIS

    # Invoked by the runner, never by hand:
    $^X -MTest2::Harness2::Preload=launch,/path/runner.socket -e '1;'

=head1 ATTRIBUTES

=over 4

=item $path = $preload->runner_socket

Absolute path to the runner's C<runner.socket> this process dials.

=item $dir = $preload->workdir

The harness workdir (the directory the sockets live in).

=back

=cut

# Role::Service wants name + workdir. The preload root identifies as
# 'preload-root' to the runner.
sub name { 'preload-root' }

# The -M import IS the entry point: with the 'launch' argument it bootstraps the
# whole process (in BEGIN/compile phase) and exits; with no/other arguments it is
# an ordinary no-op import so the module can be required/use'd (e.g. in tests)
# without launching anything.
sub import ($class, @args) {
    return unless @args && $args[0] eq 'launch';

    my (undef, $socket) = @args;

    $class->launch(runner_socket => $socket);
}

=head1 PUBLIC METHODS

=over 4

=item Test2::Harness2::Preload->launch(runner_socket => $path)

Bootstrap the preload-root process and run it to completion, then exit. Builds
the object, installs the C<Long::Jump> host frame, runs the driver, and
C<POSIX::_exit>s.

=cut

sub launch ($class, %params) {
    my $socket = $params{runner_socket}
        or croak "launch requires a runner_socket";

    my $workdir = $params{workdir};
    unless (defined $workdir && length $workdir) {
        # The sockets live in the workdir; derive it from the socket path, falling
        # back to the env the runner propagates to every child (ARCHITECTURE.md §5.3).
        my ($vol, $dir) = File::Spec->splitpath($socket);
        $workdir = File::Spec->catpath($vol, $dir, '');
        $workdir = $ENV{T2_HARNESS_WORKDIR} unless defined $workdir && length $workdir;
    }

    my $self = $class->new(runner_socket => $socket, workdir => $workdir);
    $self->{+MY_PID} = $$;

    # Establish the Long::Jump host frame at the top of the stack, in compile phase,
    # BEFORE any preloads load. A preloaded test launch (and a reload respawn) unwinds
    # HERE with no added stack frame: the stage-host Runner's fork_job_callback forks
    # the test job under a collector and longjumps 'preload-root' from the collector's
    # child, which lands below and goto::file's the test in-process.
    my $jump = setjump 'preload-root' => sub { $self->run_driver };

    # Normal driver return (no test launch / reload): the run is done, exit cleanly.
    POSIX::_exit(0) unless $jump;

    my ($action, $job, $stage) = @$jump;

    # Reload: the base stage's
    # reload check asks us to respawn the whole preload tree. Re-exec ourselves so
    # every stage reloads from a clean interpreter, exactly as the runner command
    # re-execs on its own reload.
    if ($action eq 'respawn') {
        my @inc = grep { !ref($_) && length($_) && $_ ne '.' } @INC;
        exec($^X, (map { "-I$_" } @inc), "-MTest2::Harness2::Preload=launch,$self->{+RUNNER_SOCKET}", '-e' => '1;')
            or die "preload-root respawn exec failed: $!";
    }

    die "preload-root: invalid jump action '$action'" unless $action eq 'run_test';

    # A test launch unwound to us: become the test, in-process, with the stage's
    # preloads loaded and no added stack frame.
    if (my $chdir = $job->ch_dir) {
        chdir($chdir) or die "Could not chdir: $!";
    }

    require goto::file;
    goto::file->import($job->run_file);
    Test2::Harness2::Runner::JobLauncher->cleanup_process($job, $stage);
}

=item $preload->run_driver

Dial the runner, then drive the stage host (which loads the preloads under the
guard and reports the stage map), then service the channel until stopped. Never
throws: on any error it logs
and idles until the runner reaps it, so it never voluntarily exits mid-run (a
voluntary exit would race the runner's C<waitpid(-1)> reaper).

=cut

sub run_driver ($self) {

    # The preload-root IS the nested runner now (it hosts the base/default stage
    # in-process and forks the named stages). Name it like the old in-runner host
    # BEFORE the stage host loads the preload libraries -- the base preload prints
    # "$$ $0 - Loaded ..." as it loads, and each forked stage appends "-<stage>" to
    # $0 (Preloader::launch_stage) -- so all of it is tagged `yath-nested-runner`
    # (base) / `yath-nested-runner-<stage>` for `yath watch`, not the bare `-e` of
    # the `perl -e` launch.
    $0 = 'yath-nested-runner';

    # Capture our own warnings (still printing them to STDERR for the events file) so
    # a broken-preload diagnostic -- a die in a preload, or a stage that "did not exit
    # cleanly" caught by the stage host -- can be handed to the runner with
    # stage_host_exited and surfaced in the command's output without the runner racing
    # to read our events file. (The persistent path's tolerated-broken-preload
    # warnings are surfaced separately by the stage host via preload_warnings.)
    $self->{+WARNINGS} = [];
    local $SIG{__WARN__} = sub ($msg) {
        push @{$self->{+WARNINGS}} => $msg;
        print STDERR $msg;
    };

    my $ok = eval { $self->_handshake; 1 };
    warn "$$ $0 preload-root handshake failed: $@" unless $ok;

    # Drive a stage-host Runner that hosts every stage (base/default/NOPRELOAD +
    # named). It runs the normal in-process preload + stage-fork + run_stage loop,
    # but with rootpid = the real runner's pid, so each stage becomes a socket service
    # dialing the real runner instead of an in-process root stage. process() blocks
    # until the run is done and every stage has stopped.
    if ($ok && $self->{+RUNNER_PID}) {
        my $rok = eval { $self->_run_stage_host; 1 };
        warn "$$ $0 preload-root stage host failed: $@" unless $rok;

        # Tell the runner the stage host has finished. If the runner is still waiting
        # for a stage to register (a broken preload that died before any stage came
        # up), this is its signal to stop waiting and fail fast + surface our captured
        # output (the preload error). On a normal run the runner has long since moved
        # past that wait, so this is a harmless late note. Hand over our captured
        # warnings so the runner can surface a broken-preload diagnostic.
        warn "$$ $0 preload-root could not report stage_host_exited: $@"
            unless eval { $self->service_send('runner', 'stage_host_exited', errors => ($self->{+WARNINGS} // []), want_reply => 0); 1 };    # one-way (TODO-134 finding 106)
    }

    # Idle until the runner sends 'stop'. We reach here after the stage host returns
    # (run done) or if the handshake/host setup failed -- in either case we wait to be
    # told to stop rather than exit on our own: the runner reaps us at wind-down (and
    # our collector watches the runner pid as the fallback), and a voluntary exit
    # mid-run would trip the runner's waitpid(-1) reaper.
    until ($self->{+STOPPED}) {
        $self->service_io;
        sleep 0.01;
    }

    $self->close_service;

    return;
}

# The run's settings, loaded once from the workdir's settings.json (written by the
# command before it launched us). Cached and reused by both the handshake (for the
# preload bring-up timeout) and the stage host. Dies if settings.json is absent --
# a bare preload-root with no run (e.g. a unit harness) never reaches a real run.
sub settings ($self) {
    return $self->{+SETTINGS} //= do {
        require Getopt::Yath::Settings;
        Getopt::Yath::Settings->FROM_JSON_FILE(File::Spec->catfile($self->{+WORKDIR}, 'settings.json'));
    };
}

# Build and run the stage host in this (the preload-root) process. It is a
# Test2::Harness2::Preload::Host -- an independent class from the runner (ticket
# TODO-22): it preloads, forks/hosts the stages, and launches dispatched tests, but
# it has NO scheduler and holds NO canonical run State. Its rootpid is the REAL
# runner's pid: the base/default stage is hosted in THIS process and dials the
# real runner over runner.socket (binding preload-base.socket), and preload_stages
# forks the named stages as this process's children. The test-launch fork callback
# unwinds to our 'preload-root' Long::Jump host (see launch()).
sub _run_stage_host ($self) {

    require Test2::Harness2::Preload::Host;
    require Test2::Harness2::Runner::JobLauncher;

    my $dir      = $self->{+WORKDIR};
    my $settings = $self->settings;

    my $host = Test2::Harness2::Preload::Host->new(
        $settings->runner->all,

        dir      => $dir,
        settings => $settings,
        rootpid  => $self->{+RUNNER_PID},

        # persistent ⇒ monitor on ⇒ the preloader tolerates a broken
        # preload (warn+skip); transient ⇒ monitor off ⇒ a broken preload is fatal.
        monitor_preloads => $self->{+MONITOR_PRELOADS},

        # Preload TEST jobs double-fork + detach so the collector re-parents to the
        # runner subreaper (or init) instead of being stage-reaped (ticket TODO-28). The
        # returned pid is the short-lived intermediate, which the stage reaps; the
        # detached collector self-reports its pid to the runner over its handshake.
        fork_job_callback => sub { Test2::Harness2::Runner::JobLauncher->launch_via_double_fork(@_, 'preload-root') },
    );

    $host->process();

    return;
}

=back

=head1 PRIVATE METHODS

=over 4

=item $self->_handshake

Dial the runner and request the runner pid and persistent-vs-transient flag. The
preloads are loaded later, once, under the C<test2_start_preload> guard in the
stage host -- not here.

=item $payload = $self->_request_sync($identity, $command, %args)

Send a request and pump the service loop until its correlated response arrives
(or a timeout fires).

=item $self->service_on_response($conn, $event)

L<Test2::Harness2::Role::Service> hands matched responses here; stash them by
request id for C<_request_sync>.

=back

=cut

sub _handshake ($self) {

    $self->start_service;

    my $conn = $self->service_connect_peer('runner', $self->{+RUNNER_SOCKET})
        or croak "preload-root could not connect to runner.socket at '$self->{+RUNNER_SOCKET}'";

    # Lightweight handshake: dial, identify, and ask the runner for the runner pid
    # and the persistent-vs-transient flag. The preloads are NOT loaded here -- doing
    # so would run their require-time Test2 side effects OUTSIDE the
    # test2_start_preload guard and load every module twice (once here, once in the
    # guarded stage-host preload). The stage host loads them once under the guard and
    # reports the stage map + any preload warnings from there.
    my $list = $self->_request_sync('runner', 'get_preload_list');

    # The real runner's pid: the stage host uses it as its rootpid (so it acts as a
    # stage, not the root) and conveys it down as watch_parent_pid to every
    # stage/job collector (ARCHITECTURE.md §4.1: collectors watch the runner).
    $self->{+RUNNER_PID} = $list->{runner_pid} if $list && $list->{runner_pid};

    # The real runner's monitor_preloads (on for persistent, off for
    # transient). The stage host uses it so a broken preload is tolerated
    # (warn+skip) on the persistent path and fatal on the transient path.
    $self->{+MONITOR_PRELOADS} = $list->{monitor_preloads} ? 1 : 0 if $list;

    return;
}

sub _request_sync ($self, $identity, $command, %args) {

    my $conn = $self->service_peer_conn($identity)
        or croak "no connection to peer '$identity'";

    my $request_id = $conn->send_request($command, %args)
        or croak "could not send '$command' to '$identity' (connection closed)";

    $self->{+RESPONSES} //= {};

    # The preload bring-up patience knob (--preload-map-timeout). The runner answers
    # get_preload_list instantly over the local socket, so this only bites if the
    # runner is wedged. Best-effort: before settings.json is readable (a bare
    # preload-root with no run), fall back to a 30s floor.
    my $timeout  = eval { $self->settings->runner->preload_map_timeout } || 30;
    my $deadline = mono_time + $timeout;    # pure interval -> monotonic (TODO-134 finding 104)
    until (exists $self->{+RESPONSES}{$request_id}) {
        # If the runner connection dropped mid-wait, $conn is marked closed by
        # drain on EOF during service_io. Fail fast instead of idling out the full
        # preload_map_timeout (then stalling until the process is reaped). (TODO-134
        # finding 94)
        croak "connection to '$identity' closed while waiting for '$command' response"
            if $conn->closed;
        croak "timed out waiting for '$command' response from '$identity'"
            if mono_time > $deadline;
        $self->service_io;
        sleep 0.01;
    }

    return delete $self->{+RESPONSES}{$request_id};
}

sub service_on_response ($self, $conn, $event) {

    ($self->{+RESPONSES} //= {})->{$event->{request_id}} = $event->{payload};

    return;
}

# Role::Service dispatches an inbound 'stop' request through handle_request ->
# request_handler_stop -> stop_service, which sets the role's stopped flag. Mirror
# that into our own loop flag so the driver loop ends.
sub request_handler_stop ($self, @) {
    $self->{+STOPPED} = 1;
    $self->stop_service;
    return {ok => 1, stopping => 1};
}

# A `yath reload` is NOT routed to this dormant handshake channel: the runner
# forwards the reload to the base/default stage's live channel
# (Test2::Harness2::Preload::Host::request_handler_reload_root) instead, which is
# serviced throughout a run and translates it into the in-run tree respawn. Routing
# it here would leave it unread during a run (this channel is only serviced at
# post-run idle) and risk re-execing the tree late during shutdown.

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

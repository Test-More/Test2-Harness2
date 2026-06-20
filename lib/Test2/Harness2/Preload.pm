package Test2::Harness2::Preload;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX();
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;
use File::Spec();

use Test2::Harness2::Util qw/mod2file/;

# The user-facing preload DSL / stage-tree meta. Distinct from THIS module: this
# is the preload-ROOT bootstrap process, the DSL below is the stage definition
# language a user's preload library uses.
use Test2::Harness2::Runner::Preload();

use Test2::Harness2::Util::HashBase qw{
    <runner_socket
    <workdir
    +responses
    +stopped
    +runner_pid
    +monitor_preloads
    +my_pid
    +warnings
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

    # Reload (chunk 19.4 territory; wired now so --reload works): the base stage's
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

Dial the runner, fetch the preload list, load the preloads, report the stage
map, then service the channel until stopped. Never throws: on any error it logs
and idles until the runner reaps it, so it never voluntarily exits mid-run (a
voluntary exit would race the runner's C<waitpid(-1)> reaper).

=cut

sub run_driver ($self) {

    # The preload-root IS the nested runner now (it hosts the base/default stage
    # in-process and forks the named stages). Name it like the old in-runner host
    # BEFORE the handshake loads the preload libraries -- the base preload prints
    # "$$ $0 - Loaded ..." as it loads, and each forked stage appends "-<stage>" to
    # $0 (Preloader::launch_stage) -- so all of it is tagged `yath-nested-runner`
    # (base) / `yath-nested-runner-<stage>` for `yath watch`, not the bare `-e` of
    # the `perl -e` launch.
    $0 = 'yath-nested-runner';

    # Capture our own warnings (still printing them to STDERR for the events file) so
    # a broken-preload diagnostic -- a die in a preload caught during the handshake,
    # or a stage that "did not exit cleanly" caught by the stage-host Runner -- can be
    # handed to the runner with stage_host_exited and surfaced in the command's output
    # without the runner racing to read our events file.
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
            unless eval { $self->service_send('runner', 'stage_host_exited', errors => ($self->{+WARNINGS} // [])); 1 };
    }

    # Idle until the runner sends 'stop'. We reach here after the stage host returns
    # (run done) or if the handshake/host setup failed -- in either case we wait to be
    # told to stop rather than exit on our own: the runner reaps us at wind-down (and
    # our collector watches the runner pid as the backstop), and a voluntary exit
    # mid-run would trip the runner's waitpid(-1) reaper.
    until ($self->{+STOPPED}) {
        $self->service_io;
        sleep 0.01;
    }

    $self->close_service;

    return;
}

# Build and run the stage host in this (the preload-root) process. It is a
# Test2::Harness2::Preload::Host -- an independent class from the runner (ticket
# #22): it preloads, forks/hosts the stages, and launches dispatched tests, but
# it has NO scheduler and holds NO canonical run State. Its rootpid is the REAL
# runner's pid: the base/default stage is hosted in THIS process and dials the
# real runner over runner.socket (binding preload-base.socket), and preload_stages
# forks the named stages as this process's children. The test-launch fork callback
# unwinds to our 'preload-root' Long::Jump host (see launch()).
sub _run_stage_host ($self) {

    require Getopt::Yath::Settings;
    require Test2::Harness2::Preload::Host;
    require Test2::Harness2::Runner::JobLauncher;

    my $dir      = $self->{+WORKDIR};
    my $settings = Getopt::Yath::Settings->FROM_JSON_FILE(File::Spec->catfile($dir, 'settings.json'));

    my $host = Test2::Harness2::Preload::Host->new(
        $settings->runner->all,

        dir      => $dir,
        settings => $settings,
        rootpid  => $self->{+RUNNER_PID},

        # persistent ⇒ monitor on ⇒ the preloader tolerates a broken
        # preload (warn+skip); transient ⇒ monitor off ⇒ a broken preload is fatal.
        monitor_preloads => $self->{+MONITOR_PRELOADS},

        fork_job_callback   => sub { Test2::Harness2::Runner::JobLauncher->launch_via_fork(@_, 'preload-root') },
        fork_spawn_callback => sub { Test2::Harness2::Runner::JobLauncher->launch_spawn(@_, 'preload-root') },
    );

    $host->process();

    return;
}

=item $preload->stage_data($meta)

Build the stage map reported to the runner from a merged
L<Test2::Harness2::Runner::Preload> meta object: each user-defined stage name
maps to its eager fan-out (C<can_run>) and whether it is the default. Returns an
empty hashref when there is no staged preload.

=back

=cut

sub stage_data ($self, $meta) {

    my $data = {};
    return $data unless $meta;

    my $eager   = $meta->eager_stages;
    my $lookup  = $meta->stage_lookup;
    my $default = $meta->default_stage;

    for my $name (keys %$lookup) {
        $data->{$name} = {
            can_run => $eager->{$name} // [],
            default => (defined($default) && $name eq $default) ? 1 : 0,
        };
    }

    return $data;
}

=head1 PRIVATE METHODS

=over 4

=item $self->_handshake

Dial the runner, request the preload list, load the preloads, and report the
stage map.

=item $meta = $self->_load_preloads(\@modules)

Require each preload module and merge those that expose C<TEST2_HARNESS_PRELOAD>
into one meta object. A module that fails to load is warned and skipped.

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

    my $list = $self->_request_sync('runner', 'get_preload_list');
    my @mods = @{($list && $list->{preloads}) || []};

    # The real runner's pid: the stage-host Runner uses it as its rootpid (so it acts
    # as a stage, not the root) and conveys it down as watch_parent_pid to every
    # stage/job collector (ARCHITECTURE.md §4.1: collectors watch the runner).
    $self->{+RUNNER_PID} = $list->{runner_pid} if $list && $list->{runner_pid};

    # The real runner's monitor_preloads (on for persistent, off for
    # transient). The stage-host Runner uses it so a broken preload is tolerated
    # (warn+skip) on the persistent path and fatal on the transient path.
    $self->{+MONITOR_PRELOADS} = $list->{monitor_preloads} ? 1 : 0 if $list;

    my $meta = $self->_load_preloads(\@mods);

    $self->service_send('runner', 'set_stage_data', stage_data => $self->stage_data($meta));

    # Hand any preload-load warnings (e.g. a broken preload tolerated
    # on the persistent path) to the runner so it can surface them in each run's
    # output -- on the persistent path the stage host does not exit, so these would
    # otherwise never reach a `yath run` client. This is ADDITIVE: the transient
    # fatal path still surfaces the same warnings via stage_host_exited, so WARNINGS
    # is NOT cleared here (clearing it would race queue_run and drop the transient
    # diagnostic).
    if (my @warnings = @{$self->{+WARNINGS} // []}) {
        $self->service_send('runner', 'preload_warnings', warnings => [@warnings]);
    }

    return;
}

sub _load_preloads ($self, $mods) {

    my $meta;
    for my $mod (@$mods) {
        my $file = mod2file($mod);
        my $ok = eval { require $file unless $INC{$file}; 1 };
        my $err = $@;
        unless ($ok) {
            warn "$$ $0 preload-root could not load preload '$mod': $err";
            next;
        }

        next unless $mod->can('TEST2_HARNESS_PRELOAD');

        $meta //= Test2::Harness2::Runner::Preload->new;
        $meta->merge($mod->TEST2_HARNESS_PRELOAD);
    }

    return $meta;
}

sub _request_sync ($self, $identity, $command, %args) {

    my $conn = $self->service_peer_conn($identity)
        or croak "no connection to peer '$identity'";

    my $request_id = $conn->send_request($command, %args)
        or croak "could not send '$command' to '$identity' (connection closed)";

    $self->{+RESPONSES} //= {};

    my $deadline = time + 30;
    until (exists $self->{+RESPONSES}{$request_id}) {
        croak "timed out waiting for '$command' response from '$identity'"
            if time > $deadline;
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

# The runner forwards a SIGHUP-driven reload over the channel as a 'reload'
# request (Test2::Harness2::Runner's HUP handler). Re-exec the whole preload tree
# from a clean interpreter via the 'preload-root' Long::Jump host the launch frame
# established (the same path the stage-host's respawn callback uses), so every
# stage reloads. This is only reachable in the post-run idle loop -- during a run
# the stage-host Runner owns the connection and reloads via its own SIGHUP /
# preloader->check; this covers a reload that arrives while the root idles.
sub request_handler_reload ($self, @) {
    longjump 'preload-root' => 'respawn';
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

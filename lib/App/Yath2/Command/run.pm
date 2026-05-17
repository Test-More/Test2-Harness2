package App::Yath2::Command::run;
use strict;
use warnings;

our $VERSION = '2.000013';

use POSIX ();
use Time::HiRes qw/time/;

use Test2::Harness2::Spawn;
use Test2::Harness2::Util qw/mod2file tinysleep/;

use App::Yath2::TestFile;
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
    'App::Yath2::Options::Log',
    'App::Yath2::Options::Preload',
    'App::Yath2::Options::Reloader',
    'App::Yath2::Options::Renderer',
    'App::Yath2::Options::Resource',
    'App::Yath2::Options::Runner',
    'App::Yath2::Options::Tests',
);

option_group {group => 'run', category => "Run Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of an existing yath daemon (where its IPC info file lives). Without --workdir / --ipc-file, `yath run` auto-discovers a running daemon.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When auto-discovery finds multiple running daemons, pick the most recently started one instead of erroring.',
    );
};

sub load_plugins   { 1 }
sub load_resources { 1 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 1 }

sub group { 'daemon' }

sub summary { "Run tests on a yath daemon started via `yath start`" }

sub description {
    return <<"    EOT";
Hand a list of test files to a running yath daemon (started with
`yath start`) and stream events back to the local renderer until the
run completes. Exits with the run's pass/fail aggregate.

The daemon is located automatically (this user's running daemons in
this project root). Pass --workdir DIR or --ipc-file PATH to target a
specific one, or --latest to pick the newest when multiple match.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];

    die "No test files supplied.\nUsage: yath run [--workdir DIR | --ipc-file PATH] FILE-OR-DIR [...]\n"
        unless @$args;

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $settings->run->workdir,
        latest   => $settings->run->latest,
    );
    my $ipc_path = $info->{_path};

    die "IPC info file '$ipc_path' is missing ipcm_info\n"
        unless $info->{ipcm_info};
    die "IPC info file '$ipc_path' is missing workdir\n"
        unless $info->{workdir};
    assert_daemon_alive($info);

    my $workdir = $info->{workdir};
    my $logdir  = "$workdir/logs";

    # Build a Spawn handle that points at the running daemon. The
    # daemon was spawned with watch_pids => [] by `yath start`, so
    # nothing we do here can take it down on accident -- but pin
    # terminate_on_destroy off explicitly anyway in case we evolve
    # the protocol.
    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $info->{pid},
        ipcm_info            => $info->{ipcm_info},
        workdir              => $workdir,
        terminate_on_destroy => 0,
    );

    my @files = $self->_collect_test_files($args);

    my $run_id = $self->_queue_run($spawn, \@files);

    eval { $spawn->subscribe(global => 1, run => $run_id, state => 1); 1 }
        or warn "subscribe failed: $@";

    # Fork the renderer with stop_run_id => $run_id so the Driver
    # exits naturally once this run's harness_run_end has been
    # dispatched -- yielding the same final summary `yath test`
    # prints. Without stop_run_id the Driver would block forever:
    # the daemon stays up past end-of-run so neither the on-disk
    # LIVE sentinel nor Log->EOE ever flip.
    my $renderer_pid = $self->_spawn_renderer($logdir, $spawn, $run_id);

    my ($ipc_pass) = $self->_drive_ipc_loop($spawn, $run_id, $renderer_pid);

    eval { $spawn->unsubscribe; 1 } or warn "unsubscribe failed: $@";

    # Renderer is exiting on its own (stop_run_id == $run_id matched
    # at end-of-run). Just reap it.
    my $renderer_exit = $self->_reap_renderer($renderer_pid);
    my $log_pass = $renderer_exit == 0;

    return ($ipc_pass && $log_pass) ? 0 : 1;
}

sub _collect_test_files {
    my ($self, $args) = @_;
    my @files;
    for my $arg (@$args) {
        if (-d $arg) {
            require File::Find;
            File::Find::find(
                {
                    no_chdir => 1,
                    wanted   => sub {
                        return unless -f $_ && -r _;
                        return unless /\.(?:t|t2)\z/;
                        no strict 'refs';
                        push @files => App::Yath2::TestFile->new(file => ${'File::Find::name'});
                    },
                },
                $arg,
            );
            next;
        }
        die "Not a readable test file or directory: $arg\n" unless -f $arg && -r _;
        push @files => App::Yath2::TestFile->new(file => $arg);
    }
    die "No test files matched under: @$args\n" unless @files;
    return @files;
}

sub _queue_run {
    my ($self, $spawn, $files) = @_;
    my $settings = $self->{+SETTINGS};

    my %args = (files => $files);
    if (my $hash_seed = $settings->tests->set_hash_seed) {
        $args{hash_seed} = $hash_seed if length $hash_seed;
    }
    if (my $chdir = $settings->tests->chdir) {
        $args{chdir} = $chdir if length $chdir;
    }

    # Per-run resources travel as a serializable recipe:
    #   [ [ class, key => value, ... ], ... ]
    # The harness rehydrates each entry with $class->new(@args). See
    # Test2::Harness2::request_handler_queue_test_run.
    my @resource_specs = $self->_build_resource_specs;
    $args{resources} = \@resource_specs if @resource_specs;

    my $queued = $spawn->queue_test_run(%args);
    die "queue_test_run failed: " . ($queued->{error} // '(no error)') . "\n"
        unless $queued->{ok};

    return $queued->{run_id};
}

# Build the per-run resource recipe shipped to the daemon. Per-run
# resources are additive on top of the daemon's globals; the daemon
# already owns whichever CPU/Memory/Throttle/JobCount/etc. stack the
# operator picked at `yath start` time, so re-shipping any of those
# from here would just install redundant duplicate gates bound to
# this single Run.
#
# Currently the only resource shape that genuinely belongs per-run
# is Resource::Preload with scope='run'; ship those and nothing else.
sub _build_resource_specs {
    my $self = shift;

    require App::Yath2::Preload;
    my @out;
    for my $args (App::Yath2::Preload::preload_resource_args(settings => $self->{+SETTINGS}, scope => 'run')) {
        push @out => ['Test2::Harness2::Resource::Preload', %$args];
    }

    return @out;
}

sub _spawn_renderer {
    my ($self, $logdir, $spawn, $run_id) = @_;
    my $settings    = $self->{+SETTINGS};
    my $harness_pid = $spawn->pid;

    my $pid = fork() // die "Could not fork renderer: $!";
    return $pid if $pid;

    # Child: clear inherited Spawn ownership before any teardown.
    eval { $spawn->clear_terminate_on_destroy; 1 };

    my $exit;
    my $ok = eval {
        require App::Yath2::Renderer::Driver;
        $exit = App::Yath2::Renderer::Driver->run(
            logdir      => $logdir,
            settings    => $settings,
            harness_pid => $harness_pid,
            stop_run_id => $run_id,
        );
        1;
    };
    unless ($ok) {
        my $err = $@;
        print STDERR "Renderer child died: $err\n";
        POSIX::_exit(2);
    }
    POSIX::_exit($exit // 0);
}

sub _reap_renderer {
    my ($self, $pid) = @_;
    return 0 unless $pid;
    my $got = waitpid($pid, 0);
    return 0 unless $got == $pid;
    return $? >> 8;
}

# Same flow as App::Yath2::Command::test::_drive_ipc_loop -- watch
# state broadcasts for pass/fail signals, plus poll run_results so a
# run that completed before our subscribe took effect still resolves.
sub _drive_ipc_loop {
    my ($self, $spawn, $run_id, $renderer_pid) = @_;

    my $ipc_pass     = 1;
    my $seen_run_end = 0;
    my $harness_pid  = $spawn->pid;
    my $ipc          = $spawn->handle;
    my $next_poll    = 0;

    while (1) {
        my $renderer_gone = $renderer_pid
            && (waitpid($renderer_pid, POSIX::WNOHANG()) == $renderer_pid);

        eval { $ipc->poll(0); 1 } or warn "ipc poll: $@";

        for my $msg ($ipc->messages) {
            my $content = $msg->content;
            next unless ref($content) eq 'HASH';

            next unless ($content->{type} // '') eq 'state'
                     && ($content->{item} // '') eq 'run';

            my $rd = $content->{state};
            next unless ref($rd) eq 'HASH';

            if (defined $rd->{pass}) {
                $ipc_pass = 0 unless $rd->{pass};
            }
            else {
                my $results = ref($rd->{results}) eq 'HASH' ? $rd->{results} : {};
                for my $jid (keys %$results) {
                    my $jr = $results->{$jid};
                    next unless ref($jr) eq 'HASH';
                    next unless defined $jr->{completed_at};
                    $ipc_pass = 0 unless $jr->{pass};
                }
            }

            my $pen = ref($rd->{pending}) eq 'ARRAY' ? scalar @{$rd->{pending}} : 1;
            my $run = ref($rd->{running}) eq 'ARRAY' ? scalar @{$rd->{running}} : 1;
            my $have_results = ref($rd->{results}) eq 'HASH' && %{$rd->{results}};
            $seen_run_end = 1 if $pen == 0 && $run == 0 && $have_results;
        }

        # Fall-back: poll run_results twice a second. The harness
        # records every completed run in COMPLETED_RUNS at terminal
        # time, so a run that finished before our subscribe took
        # effect (small, fast tests) still surfaces here.
        if (time >= $next_poll) {
            $next_poll = time + 0.5;
            my $res = eval { $spawn->run_results($run_id); };
            if (ref($res) eq 'HASH' && $res->{ok}) {
                my $state = $res->{state} // '';
                if ($state ne 'running' && exists $res->{pass}) {
                    $ipc_pass = 0 unless $res->{pass};
                    $seen_run_end = 1;
                }
            }
        }

        last if $seen_run_end;

        # Daemon died mid-run: bail with failure. We never saw an
        # end-of-run signal, so pass/fail is unknowable -- treat as
        # failure rather than silently returning success.
        if ($harness_pid && !kill(0 => $harness_pid)) {
            warn "yath run: harness pid $harness_pid disappeared before the run completed.\n";
            $ipc_pass = 0;
            last;
        }

        # Renderer exiting first only means the on-disk log signalled
        # end-of-run; the IPC state broadcast may still be in flight.
        # Take one more authoritative run_results poll before bailing
        # so pass/fail does not silently default to 1.
        if ($renderer_gone) {
            my $res = eval { $spawn->run_results($run_id); };
            if (ref($res) eq 'HASH' && $res->{ok} && exists $res->{pass}) {
                $ipc_pass = 0 unless $res->{pass};
            }
            else {
                # No authoritative pass/fail answer from the daemon
                # (request errored or returned no pass). The most
                # common case is the daemon went away mid-run before
                # writing the run's terminal snapshot; either way we
                # cannot honestly call this a pass, so fail closed.
                warn "yath run: run_results did not return a pass/fail; treating as failure.\n";
                $ipc_pass = 0;
            }
            last;
        }

        tinysleep(0.05);
    }

    return ($ipc_pass);
}

1;

__END__

=head1 POD IS AUTO-GENERATED

=cut

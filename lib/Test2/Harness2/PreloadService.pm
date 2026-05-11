package Test2::Harness2::PreloadService;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use POSIX ();
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util qw/mod2file/;

use Object::HashBase qw{
    <preload_name
    <modules
    <scope
    <run_id
    <is_role_consumer
    <log_path
    <ipcm_info
    <workdir
    kill_timeout
    state
    own_pgroup
    watch_pids
    +pid
    +_name
    +_pending_spawns
};

use Role::Tiny::With;
# Role::Service transitively consumes Role::ResourceService and
# IPC::Manager::Role::Service, so a single `with` here satisfies the
# host's Role::ResourceService check too.
with 'Test2::Harness2::Role::Service';

sub init {
    my $self = shift;

    # Accept the host's 'name' construction arg as preload_name; the
    # bus-level service name is derived (preload-<name> for global,
    # preload-<run_id>-<name> for run scope) so the scheduler can
    # address a preload by its preload_name + scope tuple while the
    # host-level uniqueness check sees the namespaced name.
    if (defined $self->{name} && !defined $self->{+PRELOAD_NAME}) {
        $self->{+PRELOAD_NAME} = delete $self->{name};
    }

    croak "'name' is a required attribute"
        unless defined $self->{+PRELOAD_NAME} && length $self->{+PRELOAD_NAME};
    croak "'modules' is a required attribute (arrayref, may be empty)"
        unless defined $self->{+MODULES} && ref($self->{+MODULES}) eq 'ARRAY';

    $self->{+SCOPE}            //= 'global';
    $self->{+IS_ROLE_CONSUMER} //= 0;
    $self->{+KILL_TIMEOUT}     //= 15;
    $self->{+STATE}            //= 'running';
    # WATCH_PIDS is filled in from service_on_start (after the fork)
    # via getppid(); calling getppid() here would pick up the
    # pre-fork parent (the host harness's parent process) instead of
    # the harness service itself.
    $self->{+WATCH_PIDS}       //= [];
    $self->{+OWN_PGROUP}       //= 0;
    $self->{+_PENDING_SPAWNS}  //= {};

    croak "'scope' must be 'global' or 'run'"
        unless $self->{+SCOPE} eq 'global' || $self->{+SCOPE} eq 'run';
    croak "scope='run' requires 'run_id'"
        if $self->{+SCOPE} eq 'run' && !(defined $self->{+RUN_ID} && length $self->{+RUN_ID});

    # workdir defaults to the directory containing log_path; Role::Service
    # surfaces it on the service_started event, no on-disk usage of our
    # own.
    if (!defined $self->{+WORKDIR}) {
        $self->{+WORKDIR} = defined $self->{+LOG_PATH} ? dirname($self->{+LOG_PATH}) : '.';
    }

    # Cache the bus-level name on first read.
    $self->{+_NAME} = $self->_compute_name;
}

sub _compute_name {
    my $self = shift;
    my $pn   = $self->{+PRELOAD_NAME};
    return "preload-$pn" if $self->{+SCOPE} eq 'global';
    return "preload-$self->{+RUN_ID}-$pn";
}

sub name { $_[0]->{+_NAME} //= $_[0]->_compute_name }

# Role::Service emits service_started carrying these extra fields so a
# downstream reader of the resource service's log file can tell which
# preload it is and whether the preload is a Role::Preload consumer.
sub service_started_fields {
    my $self = shift;
    return (
        preload_name     => $self->{+PRELOAD_NAME},
        preload_scope    => $self->{+SCOPE},
        preload_modules  => [@{$self->{+MODULES}}],
        is_role_consumer => $self->{+IS_ROLE_CONSUMER} ? 1 : 0,
        ($self->{+SCOPE} eq 'run' ? (preload_run_id => $self->{+RUN_ID}) : ()),
    );
}

# Minimal stub. Real implementation lands once the spawn pathway is in
# place; this will return the pids of any in-flight spawn-in-progress
# workers.
sub hard_stop_pids {
    my $self = shift;
    return ();
}

# Resource services receive log_path from the host; until the BEGIN
# block lifecycle lands the service has no STDOUT-bound EventEmitter,
# so emit_service_event is a no-op. The spawn-pathway task wires this
# up to write JSONL into log_path.
sub emit_service_event { }

# Sequential require of each module in $self->modules. Croaks with a
# clear message naming the preload + failing module + underlying
# error. Single source of truth for the require step so the harness's
# service_on_start (which awaits initial-load readiness) and a future
# reload-restart can both share the same code path.
sub do_preload {
    my $self = shift;

    for my $mod (@{$self->{+MODULES}}) {
        my $ok  = eval { $self->_require_module($mod); 1 };
        my $err = $@;
        next if $ok;

        my $preload = $self->{+PRELOAD_NAME};
        chomp(my $e = $err);
        croak "Failed to load module '$mod' for preload '$preload': $e";
    }

    return 1;
}

sub _require_module {
    my ($self, $mod) = @_;
    require( mod2file($mod) );
    return 1;
}

# Role::Service calls this from run_on_start after the pgroup /
# subreaper / service_started steps. We use it to pre-load the
# requested modules and announce readiness to the harness over the IPC
# bus. A do_preload failure propagates out of service_on_start, which
# unwinds the service's run loop and exits non-zero -- the host's
# Role::ResourceServiceHost then flips the matching Resource::Preload
# to permanent_broken (initial-load failure -> not restartable on this
# service class).
sub service_on_start {
    my $self = shift;

    # Now that we're in the forked child, getppid() returns the
    # harness service that spawned us. Adding it to watch_pids gives
    # IPC::Manager's per-tick poll a "parent gone, time to wind
    # down" signal -- without it the preload service has no
    # termination path (hard_stop_pids is empty so a terminate
    # request's escalator no-ops, and the harness's perform_hard_stop
    # waits forever for us).
    my $ppid = POSIX::getppid();
    push @{$self->{+WATCH_PIDS}}, $ppid
        if $ppid && !grep { $_ == $ppid } @{$self->{+WATCH_PIDS}};

    $self->do_preload;

    my %payload = (
        kind         => 'preload_ready',
        preload_name => $self->{+PRELOAD_NAME},
        scope        => $self->{+SCOPE},
        ($self->{+SCOPE} eq 'run' ? (run_id => $self->{+RUN_ID}) : ()),
    );

    my $client = $self->client;
    $client->send_message('harness', \%payload) if $client;

    return;
}

# Restartability matches Resource::Preload's contract: a clean exit
# flips the resource to permanent_broken so the harness reports the
# preload as gone rather than silently respawning into the same failure.
sub restartable { 0 }

# Role::Service's request_handler_terminate runs perform_hard_stop
# (which flips state to 'terminating') but does not itself exit the
# IPC loop -- the loop's per-tick run_should_end is the signal. The
# preload service has no other "we're done" condition, so any
# 'terminating' state means: drop out of run() now.
sub run_should_end {
    my $self = shift;
    return 1 if ($self->{+STATE} // '') eq 'terminating';
    return 0;
}

# No setjump wrapper -- the test grandchild runs the test file via
# `do FILE` from inside its Collector launch_callback (see
# request_handler_spawn_test below). That keeps the test inside the
# preloaded process WITHOUT an exec while leaving Collector's
# Scope::Guard intact in the surrounding stack frame.

# Async dispatch from harness. The harness calls $client->send_message
# (not send_request) so the message lands in run_on_general_message
# rather than the request/response pipeline. Route spawn_test kinds
# to request_handler_spawn_test from here.
sub run_on_general_message {
    my ($self, $msg) = @_;
    my $content = $msg->content;
    return unless ref($content) eq 'HASH';
    my $kind = $content->{kind} // $content->{request};
    return unless defined $kind && $kind eq 'spawn_test';
    return $self->request_handler_spawn_test($content, $msg);
}

# IPC handler for spawn_test from the harness. Async: no response.
# The handler runs inside the IPC loop in the service process; it
# calls Test2::Harness2::Collector->spawn with a launch_callback so
# the resulting interposed Collector forks the test grandchild
# WITHOUT exec'ing -- the grandchild inherits the preloaded %INC,
# then longjumps back to PreloadService::run's setjump anchor which
# goto::file's into the test.
#
# Process tree after this returns to the IPC loop:
#
#   preload service (this process)
#    └── collector (fork of preload service via Collector->spawn)
#         └── test grandchild (fork of collector; runs the test via
#                              longjump 'preload_spawn' + goto::file)
#
# The collector emits the standard test_job_started auditor event to
# the harness via its ipc_run wiring (pointing at the harness's bus
# name); the harness's _handle_test_job_started picks it up and
# populates the placeholder RUNNING_JOBS entry.
sub request_handler_spawn_test {
    my ($self, $payload, $msg) = @_;

    croak "spawn_test payload missing test_file_abs"
        unless defined $payload->{test_file_abs};
    croak "spawn_test payload missing run_id"
        unless defined $payload->{run_id};
    croak "spawn_test payload missing job_id"
        unless defined $payload->{job_id};

    require Test2::Harness2::Collector;

    # Callback runs in the Collector's post-fork child (the test
    # grandchild) with STDOUT/STDERR already swapped to the
    # collector's pipes. Apply env, reset $0 + Test2's
    # process-global state, then `do FILE` the test script. `do`
    # compiles and runs the file in the current process so the
    # preloaded %INC survives -- exactly what `exec` cannot give us.
    my $cb = sub {
        if (ref($payload->{env}) eq 'HASH') {
            for my $k (keys %{$payload->{env}}) {
                $ENV{$k} = $payload->{env}->{$k};
            }
        }

        my $test = $payload->{test_file_abs};
        $0 = $test;

        # Process-level reset (port from
        # reference/old2/lib/Test2/Harness2/Collector/Preloaded.pm
        # build_init_state + test2_state + final_state):
        @ARGV = ();
        srand();
        FindBin::init()                if defined &FindBin::init;
        Getopt::Long::ConfigDefaults() if defined &Getopt::Long::ConfigDefaults;

        # Reset Test2's process-global state so the test child's hub,
        # formatter, and assertion counters are fresh. The instance
        # carries a sticky FORMATTER slot that post_preload_reset
        # leaves alone, so clear it explicitly before resetting --
        # otherwise the test child inherits whatever (default TAP)
        # formatter the preload service finalized into.
        if (eval { require Test2::API; 1 }) {
            Test2::API::test2_post_preload_reset()
                if Test2::API->can('test2_post_preload_reset');

            # post_preload_reset leaves the existing Stack populated
            # with hubs from the preload-service-side Test2 usage.
            # Drain it so the next context call rebuilds a fresh
            # root hub via Stack::new_hub, which reads T2_FORMATTER
            # from %ENV at hub-build time and gives us Stream2
            # instead of the preload service's inherited (default)
            # formatter.
            if (my $stack = Test2::API::test2_stack()) {
                @$stack = ();
            }

            # post_preload_reset leaves EXIT_CALLBACKS in place;
            # plugins that registered them (Test2::Plugin::SRand,
            # etc.) re-run at the test child's END and can confuse
            # Test2's set_exit logic into flagging the test as
            # failing. Clear them via the public API.
            my $inst = $Test2::API::INST;
            if ($inst) {
                $inst->{exit_callbacks}              = [];
                $inst->{post_load_callbacks}         = [];
                $inst->{context_init_callbacks}      = [];
                $inst->{context_acquire_callbacks}   = [];
                $inst->{context_release_callbacks}   = [];
                $inst->{pre_subtest_callbacks}       = [];
                $inst->{formatter}                   = undef;
            }
        }

        # Pre-load Stream2 so the test child's first Test2::API
        # context triggers _finalize and reads T2_FORMATTER=Stream2
        # from %ENV (applied above from the spawn payload).
        eval { require Test2::Formatter::Stream2 };

        # Empty-pattern reset so the test child's "" =~ /^/ semantics
        # match a freshly-started perl rather than inheriting the
        # preload service's last-match state. Has to be dynamically
        # scoped, so it cannot be hoisted into a sub.
        "" =~ /^/;

        # Clear $@ before `do` so a post-`do` $@ check distinguishes
        # a real compile failure from a stale error left over by the
        # preload service. $! is NOT cleared because we cannot
        # reliably distinguish do's own read failure from $! changes
        # made by code inside $test (Test2's pipe writes, IO, etc.)
        # -- a -e file check is the right "did do find the file"
        # signal.
        # `do FILE` compiles the file in whatever package is currently
        # in effect at the call site, so calling it directly from this
        # closure makes the test compile in the PreloadService
        # package. Tests almost universally `use Test::More` (or
        # Test2::V0) and then call exported subs as barewords --
        # `done_testing;`, `ok(...)`, `is(...)` -- which under
        # `use strict 'subs'` only work if the import landed in the
        # package the test is being compiled into. Force `main` so the
        # test sees the same package it would have seen if it had been
        # run as `perl path/to/test.t`.
        $@ = '';
        my $r;
        {
            package main;
            $r = do $test;
        }
        my $err = $@;

        if (!defined $r) {
            if (length $err) {
                print STDERR "preload-spawn: error compiling '$test': $err\n";
                exit(255);
            }
            unless (-r $test) {
                print STDERR "preload-spawn: cannot read '$test'\n";
                exit(255);
            }
            # otherwise: file ran fine, its last expression just
            # happened to be undef (Test2's done_testing returns one
            # of these). Fall through to exit(0).
        }

        # exit (not _exit) so Test2's END finalizer fires and the
        # test's plan + assertion counts flow out through the
        # collector's STDOUT pipe before the process is torn down.
        exit(0);
    };

    my $auditor = $payload->{auditor};
    my $env     = ref($payload->{env}) eq 'HASH' ? $payload->{env} : {};

    my $handle;
    my $ok = eval {
        $handle = Test2::Harness2::Collector->spawn(
            type            => 'Job',
            id              => $payload->{job_id},
            run_id          => $payload->{run_id},
            job_try         => $payload->{job_try} // 1,
            launch_callback => $cb,
            new_pgroup      => 1,
            parent_pids     => [$$],
            env_vars        => { %$env },
            logdir          => $payload->{logdir},
            ipcm_info       => $self->ipcm_info,
            ipc_parent      => $payload->{ipc_parent},
            ipc_run         => $payload->{ipc_run},
            ipc_harness     => $payload->{ipc_harness},
            kill_timeout    => $payload->{kill_timeout},
            spec            => $payload->{spec} // {},
            (defined $auditor ? (auditor => $auditor) : ()),
            (defined $payload->{ch_dir} && length $payload->{ch_dir} ? (cwd => $payload->{ch_dir}) : ()),
        );
        1;
    };
    my $err = $@;
    unless ($ok) {
        warn "spawn_test: Collector->spawn failed: $err";
        return;
    }

    my $cpid = ref($handle) ? $handle->pid : undef;
    if (defined $cpid) {
        $self->{+_PENDING_SPAWNS}->{$cpid} = {
            run_id  => $payload->{run_id},
            job_id  => $payload->{job_id},
            started => time,
        };
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::PreloadService - Long-lived service that pre-loads
modules for a Resource::Preload.

=head1 STATUS

Skeleton. The service composes
L<Test2::Harness2::Role::Service> and
L<Test2::Harness2::Role::ResourceService>, accepts the preload identity
construction parameters that
L<Test2::Harness2::Resource::Preload/services> hands it
(C<name>, C<modules>, C<scope>, C<run_id>, C<is_role_consumer>), and
exposes them through C<service_started_fields>. The C<BEGIN> +
C<do_preload> + spawn-test plumbing lands in later tasks of the
preload-rework plan.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut

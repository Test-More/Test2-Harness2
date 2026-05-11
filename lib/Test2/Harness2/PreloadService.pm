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

# When this preload was built from a Role::Preload consumer (the -P
# classifier set is_role_consumer => 1), MODULES carries exactly one
# entry: the consumer class. Returns the class name in that case,
# undef otherwise.
sub _role_consumer_class {
    my $self = shift;
    return undef unless $self->{+IS_ROLE_CONSUMER};
    my $mods = $self->{+MODULES} // [];
    return undef unless @$mods;
    return $mods->[0];
}

# Sequential require of each module in $self->modules. Croaks with a
# clear message naming the preload + failing module + underlying
# error. Single source of truth for the require step so the harness's
# service_on_start (which awaits initial-load readiness) and a future
# reload-restart can both share the same code path.
#
# For Role::Preload consumers the require + initialization step is
# delegated to the consumer's do_preload (default supplied by the
# role itself). That call runs in the service process after the
# class has been loaded once via _require_module, so any custom
# bootstrap a consumer wants to do happens before preload_ready fires.
sub do_preload {
    my $self = shift;

    if (my $class = $self->_role_consumer_class) {
        my $ok  = eval { $self->_require_module($class); 1 };
        my $err = $@;
        unless ($ok) {
            my $preload = $self->{+PRELOAD_NAME};
            chomp(my $e = $err);
            croak "Failed to load module '$class' for preload '$preload': $e";
        }

        $ok  = eval { $class->do_preload($self); 1 };
        $err = $@;
        unless ($ok) {
            my $preload = $self->{+PRELOAD_NAME};
            chomp(my $e = $err);
            croak "do_preload failed for preload '$preload' (class '$class'): $e";
        }

        return 1;
    }

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

# Fire a Role::Preload lifecycle hook on the consumer class, if any.
# Hooks are class-method calls so consumers do not need a constructor;
# state across hooks lives in package globals on the consumer side.
# A hook exception is logged via warn but does not abort the spawn --
# pre_fork failure should not strand the harness's launch_job.
sub _fire_role_hook {
    my ($self, $hook, $payload) = @_;
    my $class = $self->_role_consumer_class or return;
    return unless $class->can($hook);

    my $ok = eval { $class->$hook($self, $payload); 1 };
    unless ($ok) {
        my $err = $@;
        chomp(my $e = $err);
        my $name = $self->{+PRELOAD_NAME};
        warn "Role::Preload hook '$hook' for preload '$name' (class '$class') failed: $e\n";
    }
    return;
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

# Tells IPC::Manager::Service::State::_ipcm_service to return rather
# than exit after run() returns. The test grandchild's longjump
# unwinds back to the setjump frame in run() (below), at which point
# we call goto::file->import to install a source filter and then
# return. _ipcm_service returns up to State::import, which is running
# at BEGIN time of the boot perl's -e snippet, and import returns;
# perl then resumes parsing -e -- but the source filter intercepts
# and feeds the test file's source into the parser instead. Test
# compiles in main with a shallow stack as if perl had been invoked
# with the test file directly.
sub run_returns_to_caller { 1 }

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

# Override the role's run() to install a setjump 'preload_spawn'
# anchor around the IPC loop. fork() copies the C + Perl stack, so
# the grandchild test process inherits this setjump frame. When the
# grandchild's spawn_test callback finishes its Test2 reset it
# longjumps 'preload_spawn' with the test path as payload, unwinding
# back here. We then arrange for the surviving perl process to
# continue as if it had been invoked with the test file directly:
# goto::file installs a source filter that feeds the test's source
# into the parser on the way out through BEGIN.
sub run {
    my $self = shift;

    require Long::Jump;
    require goto::file;

    my $jumped = Long::Jump::setjump('preload_spawn', sub {
        # IPC::Manager::Role::Service provides the run loop;
        # Test2::Harness2::Role::Service composes it without
        # overriding. Call it directly so this override doesn't
        # recurse into itself via the composed copy on $self.
        IPC::Manager::Role::Service::run($self);
    });

    # Parent / clean-shutdown path: setjump body returned without a
    # longjump. Propagate role's intended exit code (0).
    return 0 unless defined $jumped;

    # Test-grandchild path: longjump fired from
    # request_handler_spawn_test's launch_callback. setjump returns
    # an arrayref of the args longjump was given (after the tag) --
    # the callback passes the absolute test path as a single scalar
    # so $jumped is [$test_file_abs].
    my ($test_file_abs) = @$jumped;

    croak "preload longjump payload missing test_file_abs"
        unless defined $test_file_abs && length $test_file_abs;

    # The post-jump grandchild process is at runtime, but it was
    # spawned under State::import's BEGIN-time call to _ipcm_service
    # -- so the parser is still mid-parse of the boot perl's -e
    # snippet. goto::file's filter_add hooks into that snippet's
    # compilation; once run() returns, _ipcm_service + import + BEGIN
    # all unwind and perl resumes parsing -e -- where the filter
    # intercepts and feeds the test file's source.
    $0 = $test_file_abs;
    goto::file->import($test_file_abs);

    return 0;
}

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
# Drives the full launch sequence:
#
#   1. Harness sends spawn_test (this method's $payload).
#   2. PreloadService calls Collector->spawn with a launch_callback
#      so the Collector's post-fork grandchild is in-process (no
#      exec) and still owns the preloaded %INC.
#   3. Collector forks twice: child = test-collector, grandchild =
#      test-process. The launch_callback runs in the grandchild.
#   4. The callback applies env, resets process-global state
#      (Test2 hub/formatter/exit-callbacks, $0, @ARGV, srand,
#      FindBin, Getopt::Long, empty-pattern //).
#   5. The callback calls Long::Jump::longjump 'preload_spawn'
#      with the test path as payload and never returns.
#   6. Control unwinds through Collector::_launch_child_unix,
#      Collector->spawn, request_handler_spawn_test,
#      run_on_general_message, and the role's run loop, landing
#      at the setjump 'preload_spawn' anchor in
#      PreloadService::run.
#   7. run() pulls the test path out of the setjump payload and
#      calls goto::file->import($test). The source filter is now
#      attached to the boot perl's still-being-parsed -e snippet.
#   8. run() returns 0. Because PreloadService sets
#      run_returns_to_caller true, _ipcm_service returns to
#      State::import; import returns; BEGIN ends.
#   9. Perl resumes parsing -e and the goto::file filter feeds
#      the test file's source instead. Test compiles in main
#      with a shallow stack, runs to completion, and exit() fires
#      Test2's END for the plan / assertion-count flush.
#
# The collector emits the standard test_job_started auditor event
# to the harness via its ipc_run wiring (pointing at the harness's
# bus name); the harness's _handle_test_job_started picks it up
# and populates the placeholder RUNNING_JOBS entry.
#
# Process tree after this returns to the IPC loop:
#
#   preload service (this process)
#    └── collector (fork of preload service via Collector->spawn)
#         └── test grandchild (fork of collector; runs the test
#                              via longjump 'preload_spawn' +
#                              goto::file)
sub request_handler_spawn_test {
    my ($self, $payload, $msg) = @_;

    croak "spawn_test payload missing test_file_abs"
        unless defined $payload->{test_file_abs};
    croak "spawn_test payload missing run_id"
        unless defined $payload->{run_id};
    croak "spawn_test payload missing job_id"
        unless defined $payload->{job_id};

    require Test2::Harness2::Collector;
    require Long::Jump;

    # Role::Preload pre_fork hook: runs in this (service) process
    # before any forks. Use it to warm caches / open shared handles
    # that the test should inherit. Errors warn but do not abort.
    $self->_fire_role_hook(pre_fork => $payload);

    # Callback runs in the Collector's post-fork child (the test
    # grandchild) with STDOUT/STDERR already swapped to the
    # collector's pipes. Apply env, reset $0 + Test2's process-global
    # state, then longjump out to PreloadService::run's setjump
    # anchor. The post-jump branch in run() calls goto::file with the
    # test path; State::import + BEGIN unwind cleanly and perl
    # resumes parsing the boot -e snippet under the source filter
    # goto::file installed.
    my $cb = sub {
        if (ref($payload->{env}) eq 'HASH') {
            for my $k (keys %{$payload->{env}}) {
                $ENV{$k} = $payload->{env}->{$k};
            }
        }

        my $test = $payload->{test_file_abs};

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

        # Role::Preload pre_launch hook: runs in the test grandchild
        # immediately before the longjump that hands control to the
        # test file. Use it for per-test state resets that the
        # standard Test2 post-preload reset does not cover.
        $self->_fire_role_hook(pre_launch => $payload);

        # Hand off to run()'s setjump anchor. longjump unwinds all
        # the way through Collector::_launch_child_unix's eval ->
        # Collector->spawn -> request_handler_spawn_test ->
        # run_on_general_message -> role's run loop -> our setjump,
        # leaving the post-jump code in run() to call goto::file and
        # let the parser take over from there. This must be the last
        # statement in the callback; longjump never returns.
        Long::Jump::longjump('preload_spawn', $test);

        # Defensive fallback: longjump should always succeed because
        # run() installs the anchor before forks start happening. If
        # it ever does come back, treat as a contract bug and bail
        # the grandchild.
        print STDERR "preload-spawn: longjump 'preload_spawn' returned (anchor missing?)\n";
        exit(255);
    };

    my $auditor = $payload->{auditor};
    my $env     = ref($payload->{env}) eq 'HASH' ? $payload->{env} : {};

    # Role::Preload post_fork runs in the collector process (first
    # child of this service) right after fork. Only set the callback
    # when there is a role consumer; the Collector treats an unset
    # post_fork_callback as a no-op.
    my $self_ref = $self;    # capture for the closure
    my $post_fork_cb;
    if ($self_ref->_role_consumer_class) {
        $post_fork_cb = sub { $self_ref->_fire_role_hook(post_fork => $payload) };
    }

    my $handle;
    my $ok = eval {
        $handle = Test2::Harness2::Collector->spawn(
            type               => 'Job',
            id                 => $payload->{job_id},
            run_id             => $payload->{run_id},
            job_try            => $payload->{job_try} // 1,
            launch_callback    => $cb,
            ($post_fork_cb ? (post_fork_callback => $post_fork_cb) : ()),
            new_pgroup         => 1,
            parent_pids        => [$$],
            env_vars           => { %$env },
            logdir             => $payload->{logdir},
            ipcm_info          => $self->ipcm_info,
            ipc_parent         => $payload->{ipc_parent},
            ipc_run            => $payload->{ipc_run},
            ipc_harness        => $payload->{ipc_harness},
            kill_timeout       => $payload->{kill_timeout},
            spec               => $payload->{spec} // {},
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

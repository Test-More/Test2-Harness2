package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000013';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use File::Path qw/remove_tree/;
use File::Spec();
use POSIX qw/strftime :sys_wait_h/;
use Time::HiRes qw/sleep/;
use Carp qw/croak/;

use Test2::Harness2();
use App::Yath2::TestFile();
use Test2::Harness2::Util qw/mod2file tinysleep/;
use App::Yath2::Log();
use App::Yath2::Renderer::Driver();
use App::Yath2::Util::IPC qw/publish_ipc_file unlink_ipc_file/;
use Scope::Guard ();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Harness',
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::Finder',
    'App::Yath2::Options::IPC',
    'App::Yath2::Options::Log',
    'App::Yath2::Options::Renderer',
    'App::Yath2::Options::Resource',
    'App::Yath2::Options::Run',
    'App::Yath2::Options::Runner',
    'App::Yath2::Options::Scheduler',
    'App::Yath2::Options::Term',
    'App::Yath2::Options::Tests',
);

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 1 }
sub group              { 'test' }
sub summary            { 'Run a list of test files' }

sub description {
    return <<"    EOT";
Test runner. Pass a list of test files; they are executed via a
Test2::Harness2 child service. Concurrency is governed by the resource
group (--slots / -j, --job-slots / -x, --resource / -R, --no-resource).
Exits 0 if every test passed, non-zero otherwise.
    EOT
}

sub run {
    my $self = shift;

    # Autoflush both streams so any print reaches an interactive user
    # or a CI-captured log immediately.
    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];

    die "No test files supplied.\nUsage: yath test FILE-OR-DIR [...]\n"
        unless @$args;

    my @files   = $self->_collect_test_files($args);
    my $workdir = $settings->workspace->workdir;
    my $logdir  = "$workdir/logs";

    my $spawn = $self->_spawn_harness($workdir);

    my ($info_path, $ipc_guard) = $self->_publish_ipc($spawn, $workdir);

    my $run_id = $self->_queue_run($spawn, \@files);

    # Subscribe to the harness IPC bus for fast-path pass/fail signals
    # (run_state_update broadcasts, plus harness-side reflections of
    # collector_start/_end). This is the canonical "is the harness
    # done" channel; the on-disk Log is the canonical event-source for
    # the renderer.
    eval { $spawn->subscribe(global => 1, run => $run_id, state => 1); 1 }
        or warn "subscribe failed: $@";

    # Fork the renderer child early so the on-disk Log iterator picks
    # up events from the very first emission. Returns the child's pid
    # in the parent; never returns in the child.
    my $renderer_pid = $self->_spawn_renderer($logdir, $spawn);

    my ($ipc_pass, $seen_harness_end) = $self->_drive_ipc_loop($spawn, $run_id, $renderer_pid);

    # Shut the harness down BEFORE waiting on the renderer: the
    # renderer's Log iterator only flips EOE once the harness's own
    # collector has produced its harness_collector_end (which happens
    # at harness teardown). Reaping a still-running renderer here
    # would deadlock against an already-quiet harness.
    $self->_shutdown_harness($spawn);

    # Wait for the renderer child. It exits when Log->EOE returns true,
    # or with a nonzero code if the EOE-timeout safeguard fired.
    my $renderer_exit = $self->_reap_renderer($renderer_pid);

    # Final exit: combine IPC verdict + renderer exit code -- if either
    # log or ipc reports something is wrong, the result is a failure.
    # The renderer's exit code is nonzero only when the EOE safeguard
    # fired; normal renderer completion is 0 regardless of pass/fail.
    my $log_pass   = $renderer_exit == 0;
    my $final_pass = ($ipc_pass && $log_pass) ? 1 : 0;

    my $archive = $self->_resolve_archive_path;
    my $format  = lc($settings->log->format // 'tar');
    $format = 'tar.zidx' if $format eq 'tar';
    die "unknown log archive format '$format' (use 'tar' or 'sqlite')\n"
        unless $format eq 'tar.zidx' || $format eq 'sqlite';

    my $compress = $settings->log->compress ? 1 : 0;

    App::Yath2::Log->open(dir => $logdir)->archive(
        $archive,
        format   => $format,
        compress => $compress,
    );
    print "Wrote archive: $archive\n";
    App::Yath2::Log->update_last_log_symlink($archive);

    if (!$settings->workspace->keep_dirs) {
        remove_tree($workdir, {error => \my $rm_errors});
        if ($rm_errors && @$rm_errors) {
            for my $e (@$rm_errors) {
                my ($file, $msg) = %$e;
                warn "Could not remove '$file': $msg\n";
            }
        }
    }

    return $final_pass ? 0 : 1;
}

# Walk @args expanding directories via --extensions / -E filter.
# Explicit files are always accepted regardless of extension.
sub _collect_test_files {
    my ($self, $args) = @_;
    my $settings = $self->{+SETTINGS};

    my @ext    = @{$settings->finder->extensions // [qw/t t2/]};
    my $ext_re = join '|', map { quotemeta } @ext;

    my @files;
    for my $arg (@$args) {
        if (-d $arg) {
            require File::Find;
            File::Find::find(
                {
                    no_chdir => 1,
                    wanted   => sub {
                        return unless -f $_ && -r _;
                        return unless /\.(?:$ext_re)\z/;
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

    die "No test files matched extensions (@ext) under: @$args\n" unless @files;
    return @files;
}

# Spawn the harness service with the resource set the user requested.
# All slot/limiter resolution happened in Options::Resource's
# post-process; we just instantiate the classes that ended up in
# $settings->resource->classes.
sub _spawn_harness {
    my ($self, $workdir) = @_;
    my $settings = $self->{+SETTINGS};

    my @resources = $self->_build_resources;

    return Test2::Harness2->spawn(
        workdir   => $workdir,
        protocol  => $settings->ipc->protocol,
        resources => \@resources,
    );
}

# Instantiate the resource classes Options::Resource's post-process
# settled on. JobCount is the one class for which this command knows
# the slots / max_per_job mapping (so -j N:M wires through). Other
# classes are constructed with whatever args Options::Resource
# recorded for them.
sub _build_resources {
    my $self = shift;
    my $rg   = $self->{+SETTINGS}->resource;

    my $classes = $rg->classes // {};
    return () unless keys %$classes;    # --no-resource: unlimited

    my @out;
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
    return @out;
}

# Install the SIGINT/TERM/HUP handlers that clean up the IPC info
# file before the publish_ipc_file call -- otherwise a signal
# delivered during the publish would race against the cleanup guard.
# Returns ($info_path, $ipc_guard) for the caller to keep alive.
sub _publish_ipc {
    my ($self, $spawn, $workdir) = @_;
    my $settings = $self->{+SETTINGS};

    my $info_path;
    my $writer_pid = $$;
    my $ipc_guard  = Scope::Guard::guard(sub {
        unlink_ipc_file($info_path, $writer_pid) if defined $info_path;
    });

    # Scope::Guard does not fire on signal-driven exits (Perl
    # shortcuts via the C runtime without unwinding scopes). Install
    # handlers so Ctrl-C / TERM still cleans up before the process
    # dies. Each handler unlinks then re-raises with the default
    # disposition so the caller observes a normal signal exit.
    local $SIG{INT}  = sub { unlink_ipc_file($info_path, $writer_pid) if defined $info_path; $SIG{INT}  = 'DEFAULT'; kill INT  => $$ };
    local $SIG{TERM} = sub { unlink_ipc_file($info_path, $writer_pid) if defined $info_path; $SIG{TERM} = 'DEFAULT'; kill TERM => $$ };
    local $SIG{HUP}  = sub { unlink_ipc_file($info_path, $writer_pid) if defined $info_path; $SIG{HUP}  = 'DEFAULT'; kill HUP  => $$ };

    $info_path = publish_ipc_file(
        command  => 'test',
        settings => $settings,
        spawn    => $spawn,
        workdir  => $workdir,
    );

    return ($info_path, $ipc_guard);
}

# Hand the assembled file list to the harness. --set-hash-seed
# (Options::Tests) flows through verbatim when set.
sub _queue_run {
    my ($self, $spawn, $files) = @_;
    my $settings = $self->{+SETTINGS};

    my %queue_args = (files => $files);
    if (my $hash_seed = $settings->tests->set_hash_seed) {
        $queue_args{hash_seed} = $hash_seed if length $hash_seed;
    }

    my $queued = $spawn->queue_test_run(%queue_args);
    die "Could not queue run: " . ($queued->{error} // '(no error)') . "\n"
        unless $queued->{ok};

    return $queued->{run_id};
}

# Fork a renderer child process. The child runs
# App::Yath2::Renderer::Driver against the live log dir and exits when
# the iterator reports EOE (or after the stuck-EOE safeguard fires).
# Returns the pid in the parent; never returns in the child
# (POSIX::_exit).
#
# The child must NOT touch any inherited IPC handles or Spawn refs
# (their DESTROYs would otherwise terminate the harness on child
# exit). $spawn is passed in so we can clear its terminate-on-destroy
# flag in the child before any teardown.
sub _spawn_renderer {
    my ($self, $logdir, $spawn) = @_;
    my $settings    = $self->{+SETTINGS};
    my $harness_pid = $spawn->pid;

    my $pid = fork() // die "Could not fork renderer: $!";
    return $pid if $pid;

    # Child: clear inherited spawn ownership so its DESTROY does
    # not race with the parent's lifecycle management.
    eval { $spawn->clear_terminate_on_destroy; 1 };

    # Child: drive the renderer pipeline against the live log.
    my $exit;
    my $ok = eval {
        $exit = App::Yath2::Renderer::Driver->run(
            logdir      => $logdir,
            settings    => $settings,
            harness_pid => $harness_pid,
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

# Reap the renderer child. Returns its raw exit code (0 = clean
# completion, nonzero = renderer detected a problem). Tolerates a
# child that's already gone (race with shutdown).
sub _reap_renderer {
    my ($self, $pid) = @_;
    return 0 unless $pid;

    my $kid = waitpid($pid, 0);
    return 0 unless $kid == $pid;

    my $status = $? // 0;
    return $status >> 8 if $status >= 256 || $status == 0;
    return $status;
}

# Drive the parent IPC loop. Watches for run_state_update + the
# harness-side reflection of collector_end. Returns ($ipc_pass,
# $seen_harness_end):
#
#   $ipc_pass         1 if every observed run reported pass (per
#                     run_state_update.run_data.pass), 0 if any flipped
#                     to failing or marked failed.
#   $seen_harness_end 1 if we saw the harness collector emit its end
#                     reflection (or the IPC peer-down equivalent).
sub _drive_ipc_loop {
    my ($self, $spawn, $run_id, $renderer_pid) = @_;

    my $ipc_pass         = 1;
    my $seen_run_end     = 0;
    my $seen_harness_end = 0;

    my $harness_pid = $spawn->pid;
    my $harness_dead_at;
    my $harness_grace_sec = 10;

    my $ipc = $spawn->handle;

    while (1) {
        # Reap the renderer child non-blockingly; if it exits before
        # we see harness_end something is wrong but we still want to
        # let the harness drain.
        my $renderer_gone = $renderer_pid && (waitpid($renderer_pid, POSIX::WNOHANG()) == $renderer_pid);

        # Drain inbound messages from the bus.
        my $ok = eval { $ipc->poll(0); 1 };
        unless ($ok) {
            warn "ipc poll: $@";
        }

        for my $msg ($ipc->messages) {
            my $content = $msg->content;
            next unless ref($content) eq 'HASH';

            # State broadcasts: { type=>'state', item=>'run', run_id=>$id, state=>$run_data }
            my $is_run_state = ($content->{type} // '') eq 'state' && ($content->{item} // '') eq 'run';
            if ($is_run_state) {
                my $rd = $content->{state};
                next unless ref($rd) eq 'HASH';

                # Pass/fail detection: explicit pass field or computed
                # from results when the snapshot reports complete.
                if (defined $rd->{pass}) {
                    $ipc_pass = 0 unless $rd->{pass};
                }
                else {
                    # No pass key (still running) -- look at any
                    # completed jobs for a fail signal.
                    my $results = ref($rd->{results}) eq 'HASH' ? $rd->{results} : {};
                    for my $jid (keys %$results) {
                        my $jr = $results->{$jid};
                        next          unless ref($jr) eq 'HASH';
                        next          unless defined $jr->{completed_at};
                        $ipc_pass = 0 unless $jr->{pass};
                    }
                }

                # The run is complete when its scheduler has no
                # pending and no running jobs left. The run_data
                # snapshot mirrors Run::State, which carries those
                # arrays. (No top-level 'state' field is sent over
                # the wire today.)
                my $pen          = ref($rd->{pending}) eq 'ARRAY' ? scalar @{$rd->{pending}} : 1;
                my $run          = ref($rd->{running}) eq 'ARRAY' ? scalar @{$rd->{running}} : 1;
                my $have_results = ref($rd->{results}) eq 'HASH' && %{$rd->{results}};
                if ($pen == 0 && $run == 0 && $have_results) {
                    $seen_run_end = 1;
                }
                next;
            }

            # The harness-side reflection of collector_start / collector_end
            # is dispatched only as a service event in the harness's
            # log; over IPC, only run_state_update flows. Nothing else
            # to do for us here.
        }

        last if $seen_run_end;

        # If the harness pid has gone, give it a short window for any
        # final inbound state message, then bail.
        if ($harness_pid && !kill(0 => $harness_pid)) {
            $harness_dead_at //= time;
            $seen_harness_end = 1;
            last if (time - $harness_dead_at) >= $harness_grace_sec;
        }

        last if $renderer_gone && $harness_dead_at;

        tinysleep(0.05);
    }

    return ($ipc_pass, $seen_harness_end);
}

# Unsubscribe + drain pending messages while the harness is still
# alive, then ask it to finish and reap. Order matters: we only
# leave _drive_ipc_loop because we saw run state complete or the
# harness peer disappeared, so the service is generally still around
# to accept these requests. Non-fatal if the peer is gone.
sub _shutdown_harness {
    my ($self, $spawn) = @_;

    eval { $spawn->unsubscribe; 1 } or warn $@;

    # Drain stragglers, but cap the wait. The has_pending_messages
    # request itself does not count as pending work (its response
    # is queued AFTER the handler returns). 30s is generous.
    eval { $spawn->wait_until_idle(30); 1 } or warn $@;

    eval { $spawn->finish; 1 } or warn $@;
    eval { $spawn->wait;   1 } or warn $@;
}

# Resolve the archive's destination path:
#   --log-file PATH  use verbatim
#   --log-dir DIR    DIR/<stamp>.yath
#   neither          ${SYSTEM_TMP}/${project}-${user}-${stamp}-${pid}.yath
#
# SYSTEM_TMP is the original system tmpdir captured by
# App::Yath::Script before yath swaps TMPDIR for its per-invocation
# workdir. File::Spec->tmpdir() in this process returns the
# workdir-scoped tmp, which gets removed alongside the workdir at
# end of run -- so the archive must land in the original system
# tmp to survive.
sub _resolve_archive_path {
    my $self     = shift;
    my $settings = $self->{+SETTINGS};

    my $logging  = $settings->log;
    my $log_file = $logging->file;
    croak "log 'file' set to empty string"
        if defined $log_file && !length $log_file;
    return $log_file if defined $log_file;

    my $stamp   = strftime('%Y%m%d-%H%M%S', localtime);
    my $log_dir = $logging->dir;
    croak "log 'dir' set to empty string"
        if defined $log_dir && !length $log_dir;
    return File::Spec->catfile($log_dir, "$stamp.yath") if defined $log_dir;

    my $project = $settings->yath->project  // '__UNKNOWN__';
    my $user    = $settings->yath->user     // 'unknown';
    my $tmp     = $settings->yath->orig_tmp // File::Spec->tmpdir();
    return File::Spec->catfile(
        $tmp,
        "$project-$user-$stamp-$$.yath",
    );
}

1;

__END__

=head1 POD IS AUTO-GENERATED

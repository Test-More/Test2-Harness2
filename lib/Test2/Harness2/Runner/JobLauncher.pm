package Test2::Harness2::Runner::JobLauncher;
use v5.38;

our $VERSION = '2.000000';

use Config qw/%Config/;

# For some reason Filter::Util::Class breaks the STDIN filehandle. This works
# around that.
my $FIX_STDIN;

# Chunk 19.3: the goto::file filter patch (interactive STDIN handling) moves here
# with the rest of the job-launch machinery so it travels with the launcher rather
# than living in the App::Yath2 command. Whichever process is the goto-file host
# (the runner command on the no-preload path, or the preload-root on the preload
# path) loads this module and so installs the patch.
BEGIN {
    require goto::file;
    no strict 'refs';
    no warnings 'redefine';

    my $int_done;
    my $orig = goto::file->can('filter');
    *goto::file::filter = sub {
        local $.;
        my $out = $orig->(@_);
        seek(STDIN, 0, 0) if $FIX_STDIN;

        unless ($int_done++) {
            if (my $fifo = $ENV{YATH_INTERACTIVE}) {
                my $ok;
                for (1 .. 10) {
                    $ok = open(STDIN, '<', $fifo);
                    last if $ok;
                    die "Could not open fifo ($fifo): $!";
                    sleep 1;
                }

                die "Could not open fifo ($fifo): $!" unless $ok;

                print STDERR <<'                EOT';

*******************************************************************************
*                   YATH IS RUNNING IN INTERACTIVE MODE                       *
*                                                                             *
* STDIN is comming from a fifo pipe, not a TTY!                               *
*                                                                             *
* The $ENV{YATH_INTERACTIVE} var is set to the FIFO being used.               *
*                                                                             *
* VERBOSE mode has been turned on for you                                     *
*                                                                             *
* Only 1 test will run at a time                                              *
*                                                                             *
* The main yath process no longer has STDIN, so yath plugins that wait for    *
* input WILL BREAK.                                                           *
*                                                                             *
* Prompts that do not end with a newline may have a 1 second delay before     *
* they are displayed, they will be prefixed with [INTERACTIVE]                *
*                                                                             *
* Any stdin/stdout that is printed in 2 parts without a newline and more than *
* a 1 second delay will be printed with the [INTERACTIVE] prefix, if they are *
* not actually a prompt you can safely ignore them.                           *
*                                                                             *
* It is possible that a prompt was displayed before this message, please      *
* check above if your prompt appears missing. This is an IO fluke, not a bug. *
*                                                                             *
*******************************************************************************

                EOT
            }
        }

        return $out;
    };
}

use Test2::Harness2::IPC();

use Scalar::Util qw/openhandle/;

use Test2::Util qw/clone_io/;

use Long::Jump qw/longjump/;

use Test2::Harness2::Util qw/mod2file open_file process_includes/;
use Test2::Harness2::Util::IPC qw/swap_io/;

# Chunk 19.3: these were App::Yath2::Command::runner methods. They are the
# producing-side job-launch machinery (fork a test job under a collector, unwind
# to the goto-file host with no added stack frame, and finish setting up the test
# child after the goto::file swap), so they belong in Test2::Harness2 and are
# shared by both the runner command (no-preload path) and the preload-root (preload
# path). The Long::Jump host frame (setjump) and the post-jump goto::file swap stay
# in each host; the host passes its own jump LABEL into launch_via_fork so the
# unwind lands in the right frame.

sub get_stage ($class, $runner) {
    return unless $runner->can('stage');

    my $stage_name = $runner->stage     or return;
    my $preloader  = $runner->preloader or return;
    my $p          = $preloader->staged or return;

    return $p->stage_lookup->{$stage_name};
}

sub launch_spawn ($class, $runner, $spawn, $label = undef) {
    my $pid = fork() // die $!;
    if ($pid) {
        local $?;
        waitpid($pid, 0);
        return;
    }

    require POSIX;
    POSIX::setsid or die "setsid: $!";

    $pid = fork // die $!;
    exit 0 if $pid;

    eval {
        my ($wh);
        pipe(STDIN, $wh) or die "Could not create pipe: $!";
        $pid = $class->launch_via_fork($runner, $spawn, $label);

        if ($pid) {
            open(my $fh, '>>', $spawn->{task}->{ipcfile}) or die "Could not open pidfile: $!";
            print $fh "$$\n$pid\n" . fileno($wh) . "\n";
            $fh->flush();
            local $?;
            waitpid($pid, 0);
            print $fh "$?\n";
            close($fh);
        }

        exit(0);
    };
    warn "Unknown problem daemonizing: $@";
    exit(1);
}

sub launch_via_fork ($class, $runner, $job, $label = 'Test-Runner') {
    my $stage = $class->get_stage($runner);

    $stage->do_pre_fork($job) if $stage;

    my $pid = fork();
    die "Failed to fork: $!" unless defined $pid;

    # In parent
    return $pid if $pid;

    # In Child: this process becomes the Test2-Collector collector PARENT. The
    # collector forks the actual test child internally; that child runs the
    # run_sub below, which unwinds back to the host's setjump frame ($label) and
    # goto::file's in the real test -- so the test still runs in-process with
    # everything preloaded, but now under the collector's stream formatter, and its
    # full event stream is recorded to events.jsonl.zst.
    # Spawn jobs are infrastructure processes (the persistent `spawn` command's
    # workers), not test files; they must not be wrapped in a test collector.
    # Only real test Jobs become collector parents.
    my $collected = !$job->isa('Test2::Harness2::Runner::Spawn');

    my $ok = eval {
        require POSIX;
        $0 = $collected ? 'yath-collector' : 'yath-pending-test';
        setpgrp(0, 0) if Test2::Harness2::IPC::USE_P_GROUPS();
        $runner->stop();

        unless ($collected) {
            # Non-collected (spawn) path: this child IS the test process, so
            # post_fork fires here, in the same PID that will run.
            $stage->do_post_fork($job) if $stage;
            longjump $label => ('run_test', $job, $stage);
            return 1;
        }

        # Collected path: this child is the collector PARENT, not the test
        # process. The collector forks the real test child internally; post_fork
        # (and pre_launch) must fire in THAT grandchild so they share the test's
        # PID (preload contract: POST_FORK and PRE_LAUNCH are in the same PID).
        # Fire post_fork inside the collector's run sub, after the inner fork.
        my $info = $job->run_under_collector(
            run => sub {
                my ($guard) = @_;
                # The collector's child: unwind out of the collector's run_sub
                # and resume the host's own launch path, which goto::file's
                # the test in-process.
                $guard->dismiss;
                $stage->do_post_fork($job) if $stage;
                longjump $label => ('run_test', $job, $stage);
            },
        );

        # Exit with the TEST child's verdict (not the collector's own health) so
        # the runner's retry/fail logic sees the real result. See
        # Test2::Harness2::Runner::Job::_collector_exit_code.
        POSIX::_exit($job->_collector_exit_code($info));

        1;
    };
    my $err = $@;
    eval { warn $err } unless $ok;
    exit(1);
}

sub cleanup_process ($class, $job, $stage) {
    # When running under a Test2-Collector collector the collector owns the
    # child's STDOUT/STDERR (swapped onto its capture pipes) and has already
    # selected its own stream formatter (T2_FORMATTER=Collector). Skip the
    # harness's own IO redirect and Stream-formatter setup in that case.
    my $collected = ($ENV{T2_FORMATTER} // '') eq 'Collector';

    $class->update_io($job) unless $collected;    # Get the correct filehandles in place early
    $class->set_env($job);                        # Set up the necessary env vars
    $class->build_init_state($job);               # Lots of 'misc' stuff.
    $class->do_loads($job);                       # Modules that we wanted loaded/imported post fork
    $class->test2_state($job);                    # Normalize the Test2 state

    $stage->do_pre_launch($job) if $stage;

    $class->final_state($job);                    # Important final cleanup
}

sub test2_state ($class, $job) {
    if ($INC{'Test2/API.pm'}) {
        Test2::API::test2_stop_preload();
        Test2::API::test2_post_preload_reset();
    }

    # Under a Test2-Collector collector the collector selects its own stream
    # formatter (T2_FORMATTER=Collector, set in the collector child before this
    # runs) and folds in io-events itself; the harness must not install the
    # IOEvents plugin here. Real test jobs are always collected now, so there is
    # no non-collected stream-formatter fallback.
    my $collected = ($ENV{T2_FORMATTER} // '') eq 'Collector';

    if ($job->event_uuids) {
        require Test2::Plugin::UUID;
        Test2::Plugin::UUID->import();
    }

    if ($job->mem_usage) {
        require Test2::Plugin::MemUsage;
        Test2::Plugin::MemUsage->import();
    }

    if (!$collected && $job->io_events) {
        require Test2::Plugin::IOEvents;
        Test2::Plugin::IOEvents->import();
    }

    return;
}

sub final_state ($class, $job) {
    @ARGV = $job->args;

    # toggle -w switch late
    $^W = 1 if $job->use_w_switch;

    # reset the state of empty pattern matches, so that they have the same
    # behavior as running in a clean process.
    # see "The empty pattern //" in perlop.
    # note that this has to be dynamically scoped and can't go to other subs
    "" =~ /^/;

    return;
}

sub do_loads ($class, $job) {
    local $@;
    my $importer = eval <<'    EOT' or die $@;
package main;
#line 0 "-"
sub { $_[0]->import(@{$_[1]}) }
    EOT

    for my $set ($job->load_import) {
        my ($mod, $args) = @$set;
        my $file = mod2file($mod);
        local $0 = '-';
        require $file;
        $importer->($mod, $args);
    }

    for my $mod ($job->load) {
        my $file = mod2file($mod);
        local $0 = '-';
        require $file;
    }

    return;
}

sub build_init_state ($class, $job) {
    $0 = $job->rel_file;
    $class->_reset_DATA();
    @ARGV = ();

    srand();    # avoid child processes sharing the same seed value as the parent

    @INC = process_includes(
        list            => [$job->includes],
        include_dot     => $job->unsafe_inc,
        include_current => 1,
        clean           => 1,
    );

    # if FindBin is preloaded, reset it with the new $0
    FindBin::init() if defined &FindBin::init;

    # restore defaults
    Getopt::Long::ConfigDefaults() if defined &Getopt::Long::ConfigDefaults;

    return;
}

sub set_env ($class, $job) {
    my $env = $job->env_vars;
    {
        no warnings 'uninitialized';
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    $ENV{T2_HARNESS_FORKED}  = 1;
    $ENV{T2_HARNESS_PRELOAD} = 1;

    return;
}

sub update_io ($class, $job) {
    my $out_fh = open_file($job->out_file, '>');
    my $err_fh = open_file($job->err_file, '>');

    my $in_file = $job->in_file;
    my $in_fh;
    $in_fh = open_file($in_file, '<') if $in_file;

    $out_fh->autoflush(1);
    $err_fh->autoflush(1);

    # Keep a copy of the old STDERR for a while so we can still report errors
    my $stderr = clone_io(\*STDERR);

    my $die = sub {
        my @caller  = caller;
        my @caller2 = caller(1);
        my $msg     = "$_[0] at $caller[1] line $caller[2] ($caller2[1] line $caller2[2]).\n";
        print $stderr $msg;
        print STDERR $msg;
        POSIX::_exit(127);
    };

    swap_io(\*STDIN,  $in_fh,  $die, '<&') if $in_file;
    swap_io(\*STDOUT, $out_fh, $die, '>&');
    swap_io(\*STDERR, $err_fh, $die, '>&');

    $FIX_STDIN = 1 if $in_file;

    return;
}

# Heavily modified from forkprove
sub _reset_DATA ($class) {
    for my $set (@{$class->preload_list}) {
        my ($mod, $file, $pos) = @$set;

        my $fh = do {
            no strict 'refs';
            *{$mod . '::DATA'};
        };

        # note that we need to ensure that each forked copy is using a
        # different file handle, or else concurrent processes will interfere
        # with each other

        close $fh if openhandle($fh);

        if (open $fh, '<', $file) {
            seek($fh, $pos, 0);
        }
        else {
            warn "Couldn't reopen DATA for $mod ($file): $!";
        }
    }
}

# Heavily modified from forkprove
sub preload_list ($class) {
    my $list = [];

    for my $loaded (keys %INC) {
        next unless $loaded =~ /\.pm$/;

        my $mod = $loaded;
        $mod =~ s{/}{::}g;
        $mod =~ s{\.pm$}{};

        my $fh = do {
            no strict 'refs';
            no warnings 'once';
            *{$mod . '::DATA'};
        };

        next unless openhandle($fh);
        push @$list => [$mod, $INC{$loaded}, tell($fh)];
    }

    return $list;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::JobLauncher - Producing-side goto-file job launcher.

=head1 DESCRIPTION

The machinery that forks a test job under a L<Test2::Collector> collector,
unwinds out of the collector's C<run_sub> back to a L<Long::Jump> host frame with
no added stack frame, and -- after the host C<goto::file>s the test in -- finishes
preparing the test child (IO, env, C<@INC>, C<DATA> handles, Test2 state, and the
preload C<pre_launch> hook).

This used to live in C<App::Yath2::Command::runner>. It is producing-results
work, so it lives in C<Test2::Harness2> (the dependency rule forbids
C<Test2::Harness2> loading C<App::Yath2*>, and the B<preload-root>
(L<Test2::Harness2::Preload>) is a C<Test2::Harness2> process that needs this
launcher). Both the runner command (the no-preload path) and the preload-root (the
preload path) reuse it; each keeps its own C<Long::Jump> host frame and passes its
jump B<label> into C<launch_via_fork> so the unwind lands in the right frame.

=head1 PUBLIC METHODS

=over 4

=item $pid = Test2::Harness2::Runner::JobLauncher->launch_via_fork($runner, $job, $label)

Fork a job. In the parent, return the child pid. In the child (the collector
parent for a real test, or the test process itself for a non-collected spawn),
unwind to the host's C<setjump $label> frame via L<Long::Jump> so the host can
C<goto::file> the test in-process. C<$label> defaults to C<'Test-Runner'>.

=item Test2::Harness2::Runner::JobLauncher->launch_spawn($runner, $spawn, $label)

Double-fork + C<setsid> a detached C<yath spawn> worker, then launch it via
C<launch_via_fork>.

=item Test2::Harness2::Runner::JobLauncher->cleanup_process($job, $stage)

Run after the host's C<goto::file> swap: finish preparing the test child (IO, env,
C<@INC>, loads, Test2 state, the stage C<pre_launch> hook, and final cleanup).

=item $stage = Test2::Harness2::Runner::JobLauncher->get_stage($runner)

The L<Test2::Harness2::Runner::Preload::Stage> the runner is currently hosting, or
undef.

=back

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

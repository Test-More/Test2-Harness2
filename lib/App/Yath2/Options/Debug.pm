package App::Yath2::Options::Debug;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util::JSON qw/encode_pretty_json/;
use Test2::Util::Table qw/table/;
use Test2::Harness2::Util qw/find_libraries mod2file clean_path/;

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Debug - Debug options for Yath

=head1 DESCRIPTION

This is where debug related command line options live.

=head1 PROVIDED OPTIONS

=head3 Help and Debugging

=over 4

=item -d

=item --dummy

=item --no-dummy

Dummy run, do not actually execute anything

Can also be set with the following environment variables: C<T2_HARNESS_DUMMY>

The following environment variables will be cleared after arguments are processed: C<T2_HARNESS_DUMMY>


=item -h

=item -h=Group

=item --help

=item --help=Group

=item --no-help

exit after showing help information


=item -i

=item --interactive

=item --no-interactive

Use interactive mode, 1 test at a time, stdin forwarded to it


=item -k

=item --keep-dir

=item --keep-dirs

=item --no-keep-dirs

Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.


=item --procname-prefix ARG

=item --procname-prefix=ARG

=item --no-procname-prefix

Add a prefix to all proc names (as seen by ps).


=item --show-opts

=item --show-opts=group

=item --no-show-opts

Exit after showing what yath thinks your options mean


=item --summary

=item --summary=/path/to/summary.json

=item --no-summary

Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.


=item -V

=item --version

=item --no-version

Exit after showing a helpful usage message


=back


=cut

option_group {group => 'debug', category => 'Help and Debugging'} => sub {
    option dummy => (
        type           => 'Bool',
        short          => 'd',
        description    => 'Dummy run, do not actually execute anything',
        from_env_vars  => [qw/T2_HARNESS_DUMMY/],
        clear_env_vars => [qw/T2_HARNESS_DUMMY/],
        default        => 0,
    );

    option procname_prefix => (
        type        => 'Scalar',
        default     => '',
        description => 'Add a prefix to all proc names (as seen by ps).',
    );

    option keep_dirs => (
        type        => 'Bool',
        short       => 'k',
        alt         => ['keep-dir'],
        description => 'Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.',
        default     => 0,
    );

    option 'show-opts' => (
        type           => 'Auto',
        autofill       => 1,
        description    => 'Exit after showing what yath thinks your options mean',
        short_examples => ['', '=group'],
        long_examples  => ['', '=group'],
    );

    option version => (
        type        => 'Bool',
        short       => 'V',
        description => "Exit after showing a helpful usage message",
    );

    option help => (
        type           => 'Auto',
        autofill       => 1,
        short          => 'h',
        description    => "exit after showing help information",
        short_examples => ['', '=Group'],
        long_examples  => ['', '=Group'],
    );

    option interactive => (
        type        => 'Bool',
        short       => 'i',
        description => 'Use interactive mode, 1 test at a time, stdin forwarded to it',
    );

    option summary => (
        type          => 'Auto',
        autofill      => sub { clean_path('summary.json') },
        description   => "Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.",
        long_examples => ['', '=/path/to/summary.json'],
        normalize     => \&normalize_summary,
        applicable    => sub ($opt, $options, $settings) {
            return 1 if $options && $options->option_groups->{run};
            return 0;
        },
    );
};

option_post_process 99999 => \&_post_process_show_opts;
option_post_process 99998 => \&_post_process_interactive;
option_post_process 85    => \&_post_process_interactive_display;
option_post_process 0     => \&_post_process_version;
option_post_process 0     => \&_post_process_help;

sub normalize_summary ($val) {
    return clean_path('summary.json') if !defined($val) || $val eq '1';

    $val =~ s/\.json$//g;
    $val .= '.json';

    return clean_path($val);
}

sub _print_command_banner ($settings) {
    # Guard command access defensively — wired in a later task
    return unless $settings->check_group('harness') && $settings->harness->check_option('command');
    my $cmd_class = $settings->harness->command;
    print "\nCommand selected: " . $cmd_class->name . "  (" . $cmd_class . ")\n" if $cmd_class;
}

sub _post_process_help ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->debug->help;

    # Defer to the help command when it is the resolved command. This lets
    # `yath --help` (and `yath -h`) with no command word fall through to
    # help->run(), which prints the command table. When a real command was
    # resolved (e.g. `yath --help test`) we do NOT defer: we print that
    # command's help here and exit.
    if ($settings->check_group('harness') && $settings->harness->check_option('command')) {
        my $cmd_class = $settings->harness->command;
        return if $cmd_class && $cmd_class->isa('App::Yath2::Command::help');
    }

    my $group = $settings->debug->help;

    _print_command_banner($settings);

    my $help = $options->docs('cli', settings => $settings, ($group && $group ne '1' ? (group => $group) : ()));

    my $ok  = eval { require IO::Pager; 1 };
    my $err = $@;
    if ($ok) {
        local $SIG{PIPE} = sub { };
        # The help text is ANSI-colored; tell less to pass color through (-R)
        # or it renders the raw escapes literally ("ESC[1;4;37m..."). Preserve
        # any LESS the user already set.
        local $ENV{LESS} = join ' ', grep { defined && length } ($ENV{LESS}, '-R');
        my $pager = IO::Pager->new(*STDOUT);
        $pager->print($help);
    }
    else {
        print $help;
    }

    exit 0;
}

sub _post_process_show_opts ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->debug->show_opts;

    _print_command_banner($settings);

    # Mirror the final argv assembly in App::Yath2::process_argv(): ordinary
    # positional args land in 'skipped' under skip_non_opts, only post-stop
    # args land in 'remains'. Reading 'remains' alone dropped the command args.
    my @cmd_args = @{$state->{skipped} // []};
    push @cmd_args => $state->{stop} if defined $state->{stop};
    push @cmd_args => @{$state->{remains} // []};
    print "\nCommand args: " . join(', ' => @cmd_args) . "\n" if @cmd_args;

    my $group = $settings->debug->show_opts;
    my $out =
        $group eq '1'
        ? encode_pretty_json($settings)
        : encode_pretty_json($settings->check_group($group) ? $settings->$group : "!! Invalid Group '$group' !!");

    print "\nCurrent command line and config options result in these settings:\n";
    print "$out\n";

    exit 0;
}

my $RAN = 0;

# Interactive mode shares ONLY the command's STDIN with one test at a time (-j1),
# by passing the real STDIN descriptor over a Unix socket (SCM_RIGHTS) rather than
# proxying bytes through a FIFO. STDOUT/STDERR stay with the collector and render
# normally. The command opens a listen socket here, advertises its path in
# $ENV{YATH_INTERACTIVE} (and the run env, so it reaches the test child), then
# forks: the parent keeps the real STDIN and runs a per-test accept loop (passes
# the STDIN fd once per sequential test); the child gives up STDIN and continues
# as the yath command. Each test (preload goto::file filter, or no-preload
# -MTest2::Harness2::Interactive) dials in and dup2s the received fd onto fd 0.
sub _post_process_interactive ($options, $state) {
    return if $RAN++;

    my $settings = $state->{settings};

    return unless $settings->debug->interactive;

    # Interactive needs IO::FDPass to pass the STDIN descriptor. It is an optional
    # dependency, so fail early here (at the command, before any run is queued)
    # with an actionable message rather than crashing deep in a worker.
    require Test2::Harness2::Util::FdPass;
    Test2::Harness2::Util::FdPass::require_fdpass('Interactive mode');

    my ($listen, $path) = Test2::Harness2::Util::FdPass::command_listen();

    _interactive_apply_settings($settings, $path);

    my $pid = fork() // die "Could not fork: $!";

    if ($pid) {
        # Parent: owns the real STDIN; pass it to each test as it dials in.
        _interactive_accept_loop($listen, $path, $pid);
    }

    # Child (the yath command): give up the listener and STDIN -- the parent owns
    # them now. The main yath process no longer has STDIN (plugins that read it
    # will break, as documented).
    close($listen);
    close(STDIN);
    open(STDIN, '<', '/dev/null');

    return;
}

# (77) Interactive's display/formatter overrides. These MUST land before Display
# resolves renderers (its posts run at weight 90/100) -- Getopt::Yath runs posts
# in ASCENDING weight (Instance.pm `sort { $a <=> $b }`) -- so this post is
# registered at weight 85. Previously these mutations lived in
# _interactive_apply_settings, which runs at 99998 (after Display), so with -q
# the Formatter renderer was already deleted and with -i verbose=1 arrived too
# late to set show_job_launch, freezing it off in the resolved args.
#
# NO $RAN guard: $RAN protects only the fork in _post_process_interactive. This
# post is idempotent, so re-running it (e.g. help/version replay) is harmless.
# --live defaults ON (output must stream while a test prompts), -v ON, quiet
# OFF, qvf OFF. Weight band 1-89 is otherwise empty codebase-wide, so 85
# reorders nothing else.
sub _post_process_interactive_display ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->debug->interactive;

    if ($settings->check_group('display')) {
        my $display = $settings->display;
        $display->create_option(quiet   => 0) if $display->check_option('quiet');
        $display->create_option(verbose => 1) if $display->check_option('verbose') && !$display->verbose;

        # Interactive mode runs one test at a time with stdin forwarded, so its
        # output must stream live rather than being held until the job ends.
        # Default --live ON here unless the user already set it.
        $display->create_option(live => 1) if $display->check_option('live') && !$display->live;
    }

    if ($settings->check_group('formatter')) {
        my $formatter = $settings->formatter;
        $formatter->create_option(qvf => 0) if $formatter->check_option('qvf');
    }

    return;
}

# Advertise the interactive listen-socket path so the test child can dial back:
# into the run env (the only transport to a PERSISTENT runner's jobs) and our
# own %ENV. The display/formatter defaults are applied separately at weight 85
# (_post_process_interactive_display) so they settle before Display resolves
# renderers. NOTE: connect_stdin scrubs YATH_INTERACTIVE from the test's live
# %ENV once the handshake completes (see Test2::Harness2::Interactive) -- the
# path is present only up to that point, never while test-body code runs.
sub _interactive_apply_settings ($settings, $path) {
    if ($settings->check_group('run')) {
        $settings->run->create_option(env_vars => {}) unless $settings->run->check_option('env_vars');
        $settings->run->env_vars->{YATH_INTERACTIVE} = $path;
    }

    $ENV{YATH_INTERACTIVE} = $path;

    return;
}

# The command-side per-test accept loop. -j1 means N sequential tests; each dials
# the listen socket once and we pass it the real STDIN descriptor, then close the
# connection and wait for the next test. The loop ends when the yath command
# child exits; we then unlink the socket and forward the child's exit code. A
# connect that never arrives is bounded by the child's lifetime (the select wakes
# periodically to re-check that the child is alive). Ctrl-C (INT/TERM) is
# forwarded to the child rather than exiting immediately, so the workdir tempdir
# (whose File::Temp END cleanup is keyed to this parent) is torn down only after
# the child, runner, and collectors have finished with it (TODO-125).
sub _interactive_accept_loop ($listen, $path, $pid) {
    require POSIX;

    my $cleanup = sub { unlink($path) if defined $path && -e $path };

    my $finish = sub {
        my ($exit) = @_;
        $cleanup->();
        exit($exit // 0);
    };

    # TODO-125: INT/TERM must NOT exit here. The workdir tempdir was created in this
    # (pre-fork) process, so File::Temp keys its END cleanup to US (the child's $$
    # differs, so the child can never clean it -- this parent's exit is the ONLY
    # workdir cleanup in interactive mode). Exiting the instant Ctrl-C arrives
    # would remove_tree the workdir out from under the yath child, runner, and
    # collectors while they are still mid-shutdown and writing into it -- events
    # files vanish mid-write and the shell prompt returns over live children.
    #
    # Instead: forward the signal to the child so it shuts down gracefully and
    # record it in $signaled; DO NOT exit. The waitpid loop below reaps the child
    # and exits through the TODO-140-owned status expression, so File::Temp's END
    # cleanup fires only after every workdir user is gone. Repeated signals
    # escalate (INT/TERM as asked, then SIGKILL on the third) so a child that
    # ignores the signal cannot wedge this parent forever -- but even the escalated
    # kill routes its exit through the single waitpid path, never exiting here.
    my $signaled = 0;
    my $forward = sub ($sig) {
        $signaled++;
        kill(($signaled >= 3 ? 'KILL' : $sig) => $pid);
    };
    local $SIG{INT}  = sub { $forward->('INT') };
    local $SIG{TERM} = sub { $forward->('TERM') };
    local $SIG{PIPE} = 'IGNORE';

    my $rin = '';
    vec($rin, fileno($listen), 1) = 1;

    while (1) {
        # Reap the command child if it has exited; that ends the run.
        #
        # TODO-140 owns this STATUS COMPUTATION -- exactly the two $finish lines
        # below. TODO-125 owns exit TIMING/sequencing: the INT/TERM handler bodies
        # and the $cleanup/$finish shape it reworks for deferred-tempdir
        # cleanup. When TODO-125 restructures this loop it MUST route every exit
        # through this expression verbatim -- its step 2 ("propagate signal
        # deaths as 128+sig") is DELIVERED HERE and must not be re-derived.
        #
        # WNOHANG waitpid: 0 = still running; $pid = reaped, so $? is valid --
        # ($? & 127) is the terminating signal (bit 7, the coredump flag, is
        # correctly excluded) and ($? >> 8) is the exit code, so a signal death
        # (OOM SIGKILL -> 137, segfault -> 139) is no longer masked as 0/green;
        # -1 = ECHILD (e.g. an inherited SIG_IGN CHLD auto-reaping the child),
        # where $? is meaningless -- exit nonzero (1) rather than poll forever.
        my $got = waitpid($pid, POSIX::WNOHANG());
        $finish->(($? & 127) ? 128 + ($? & 127) : ($? >> 8)) if $got == $pid;

        # ECHILD: $? is unrecoverable, so exit nonzero (1) instead of polling forever.
        $finish->(1) if $got < 0;

        my $ready = select(my $rout = $rin, undef, undef, 0.2);
        next unless $ready && $ready > 0;

        my $conn = $listen->accept or next;
        _interactive_pass_stdin($conn);
        close($conn);
    }
}

# Pass the command's real STDIN descriptor to one dialed-in test. Failures here
# (a test that dies mid-handshake, a closed socket) must not take the command
# down -- the next test gets its own connection -- so the send is eval-guarded
# and a failure is warned, not fatal.
sub _interactive_pass_stdin ($conn) {
    my $ok = eval { Test2::Harness2::Util::FdPass::send_fds($conn, [fileno(\*STDIN)]); 1 };
    unless ($ok) {
        warn "Interactive: failed to pass STDIN to a test: $@";
        return;
    }

    # (G6) Attribution, NOT authorization: log one STDERR line per fd-pass so a
    # SECOND pass during a single test -- a harness-aware descendant that
    # recovered the socket path and dialed in to steal the terminal STDIN -- is
    # visible on the terminal instead of silent. SO_PEERCRED gives best-effort
    # (Linux-only) peer pid/uid; on any failure we still log, just without them.
    require Socket;
    my ($cpid, $cuid);
    my $ok2 = eval {
        my $cred = getsockopt($conn, Socket::SOL_SOCKET(), Socket::SO_PEERCRED());
        ($cpid, $cuid) = unpack('lll', $cred) if defined $cred && length $cred;
        1;
    };
    my $err = $@;

    if (defined $cpid) {
        warn "Interactive: passed STDIN to a dialer (pid $cpid uid $cuid)\n";
    }
    else {
        warn "Interactive: passed STDIN to a dialer (peer identity unavailable)\n";
    }

    return;
}

sub _post_process_version ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->debug->version;

    require App::Yath2;
    my $out = <<"    EOT";

Yath version: $App::Yath2::VERSION

Extended Version Info
    EOT

    my $plugin_libs = find_libraries('App::Yath2::Plugin::*');

    my @vers = (
        [perl         => $^V],
        ['App::Yath2' => App::Yath2->VERSION],
        (
            map {
                my $ok = eval { require(mod2file($_)); 1 };
                $ok
                    ? [$_ => $_->VERSION // 'N/A']
                    : [$_ => 'N/A']
            } qw/Test2::API Test2::Suite Test::Builder/
        ),
        (
            map {
                my $ok = eval { require($plugin_libs->{$_}); 1 };
                $ok ? [$_ => $_->VERSION // 'N/A'] : ()
            } sort keys %$plugin_libs
        ),
    );

    $out .= join "\n" => table(
        header => [qw/COMPONENT VERSION/],
        rows   => \@vers,
    );

    print "$out\n\n";

    exit 0;
}

1;

__END__

=pod

=encoding UTF-8

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

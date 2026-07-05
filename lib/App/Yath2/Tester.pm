package App::Yath2::Tester;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::API qw/context run_subtest/;
use Test2::Tools::Compare qw/is/;

use Carp qw/croak/;
use File::Spec;
use File::Find ();
use File::Temp qw/tempfile tempdir/;
use POSIX;
use Fcntl qw/SEEK_CUR/;
use Time::HiRes ();

use App::Yath2::Util qw/find_yath/;
use Test2::Harness2::Util qw/clean_path apply_encoding/;
use Test2::Harness2::Util::IPC qw/run_cmd/;
use Test2::Harness2::Util::File::JSONL;

use Importer Importer => 'import';
our @EXPORT = qw/yath make_example_dir/;

my $pdir = tempdir(CLEANUP => 1);

# Route every persistent runner's discovery symlink into our process-unique $pdir
# (find_runner_link honors YATH_PERSISTENCE_DIR). Without this the default location
# is $TMPDIR/.<user>-<host>-<project>-yath-runner.sock -- shared by EVERY
# persistent-runner test in the suite (same project, same /tmp) -- so concurrent
# tests under `prove -j` collide ("Persistent harness appears to be running")
# and flake (notably reload.t). Per-process isolation removes the collision, and
# it is what _shutdown_persistent_runners (which scans $pdir) already assumes.
$ENV{YATH_PERSISTENCE_DIR} //= $pdir;

# A persistent runner started during a test (yath start) detaches and outlives
# the command that started it. If the test dies, times out, or is signalled
# before its `yath stop`, that runner would leak -- and keep respawning its
# preload stages forever. Stop every runner whose discovery symlink lives under
# our $pdir on the way out, however we exit. The symlink points at the runner's
# workdir/runner.socket; the runner's own pid is read from workdir/PID. Registered
# after File::Temp's tempdir cleanup so (LIFO) this runs first, while the symlinks
# still exist. A SIGKILL of the test process bypasses both this and File::Temp; the
# runner's own orphan guard (it self-exits when its workdir/symlink vanishes) is
# the fallback for that case.
sub _shutdown_persistent_runners {
    return unless -d $pdir;

    my @links;
    File::Find::find(
        {no_chdir => 1, follow => 0, wanted => sub { push @links => $_ if m/yath-runner\.sock\z/ && -l $_ }},
        $pdir,
    );

    for my $link (@links) {
        my $target = readlink($link) or next;
        my ($vol, $dir, undef) = File::Spec->splitpath($target);
        my $pidfile = File::Spec->catpath($vol, $dir, 'PID');
        next unless -f $pidfile;

        open(my $fh, '<', $pidfile) or next;
        my $pid = <$fh>;
        close($fh);
        chomp($pid) if defined $pid;
        next unless defined($pid) && $pid =~ /^\d+$/;
        next unless kill(0 => $pid);
        kill('TERM', $pid);
    }
}

END { _shutdown_persistent_runners() }

for my $sig (qw/INT TERM/) {
    my $prev = $SIG{$sig};
    $SIG{$sig} = sub {
        _shutdown_persistent_runners();
        if   (ref $prev) { $prev->(@_) }
        else             { $SIG{$sig} = 'DEFAULT'; kill($sig => $$) }
    };
}

require App::Yath2;
my $apppath = App::Yath2->app_path;

sub cover {
    return unless $ENV{T2_DEVEL_COVER};
    $ENV{T2_COVER_SELF} = 1;
    return '-MDevel::Cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';
}

sub yath {
    my %params = @_;

    # Localized so the waitpid/system machinery below cannot clobber the
    # caller's $?.
    local $?;

    my $ctx = context();

    my $p = _parse_params(\%params);

    my $stdin_fh = _setup_stdin($p->{stdin});

    # Capture the caller's file here (not in a helper) so inc-detection finds
    # the test file that called yath(), not this module's frame.
    my (undef, $caller_file) = caller();

    my $run = _setup_capture_and_log($p, $caller_file);

    # Localized for the whole run *and* the result subtest below, so the
    # caller's test block observes the same environment the command ran under.
    local %ENV = %ENV;

    # App::Yath::Script (2.0) prints a message and sets PERL_HASH_SEED when
    # it is not already set, which pollutes captured output.
    $ENV{PERL_HASH_SEED} //= POSIX::strftime('%Y%m%d', localtime);

    $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    $ENV{YATH_CMD}             = $p->{cmd};
    $ENV{NESTED_YATH}          = 1;
    $ENV{'YATH_SELF_TEST'}     = 1;
    $ENV{$_} = $p->{env}->{$_} for keys %{$p->{env}};

    my ($exit, $lines) = _run_and_capture($p, $run, $stdin_fh);

    my $out = {
        exit => $exit,
        $p->{capture} ? (output => join('', @$lines)) : (),
        # Constructed after waitpid: the log is complete, so done => 1 surfaces a
        # newline-less final record instead of silently dropping it.
        $p->{log} ? (log => Test2::Harness2::Util::File::JSONL->new(name => $run->{logfile}, done => 1)) : (),
    };

    _report_result($p, $out, $run->{cmd});

    $ctx->release;

    return $out;
}

# Pull the recognized yath() arguments (with their aliases) out of the arg hash,
# apply defaults, and croak on anything left over. Returns a hashref.
sub _parse_params {
    my ($params) = @_;

    my %p;
    $p{cmd}    = delete $params->{cmd} // delete $params->{command};
    $p{cli}    = delete $params->{cli} // delete $params->{args} // [];
    $p{pre}    = delete $params->{pre} // delete $params->{pre_command} // [];
    $p{env}    = delete $params->{env} // {};
    $p{enc}    = delete $params->{encoding};
    $p{prefix} = delete $params->{prefix};

    $p{subtest}  = delete $params->{test} // delete $params->{tests} // delete $params->{subtest};
    $p{exittest} = delete $params->{exit};

    $p{debug}   = delete $params->{debug}   // 0;
    $p{inc}     = delete $params->{inc}     // 1;
    $p{capture} = delete $params->{capture} // 1;
    $p{log}     = delete $params->{log}     // 0;
    $p{stdin}   = delete $params->{stdin};

    $p{no_app_path} = delete $params->{no_app_path};
    $p{lib}         = delete $params->{lib} // [];

    if (keys %$params) {
        croak "Unexpected parameters: " . join(', ', sort keys %$params);
    }

    return \%p;
}

# Optional STDIN for the yath process (e.g. interactive mode feeds the
# command's STDIN through to the one running test). A string is written to a
# temp file and rewound; an open handle is used as-is. Returns undef for none.
sub _setup_stdin {
    my ($stdin) = @_;

    return undef unless defined $stdin;
    return $stdin if ref $stdin;

    my ($stdin_fh, $sfile) = tempfile("yathin-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.in');
    print $stdin_fh $stdin;
    $stdin_fh->flush;
    seek($stdin_fh, 0, 0);

    return $stdin_fh;
}

# Build the yath command line (dev-libs from the caller's test dir, app-path
# includes, coverage, log args) plus the capture and log temp files. Returns a
# hashref: cmd (arrayref), wh/cfile (capture handle+path), logfile.
sub _setup_capture_and_log {
    my ($p, $caller_file) = @_;

    my $cmd   = $p->{cmd};
    my $debug = $p->{debug};

    my (@inc, @dev);
    if ($p->{inc}) {
        my $dir = $caller_file;
        $dir =~ s/\.t2?$//g;

        my $incdir = File::Spec->catdir($dir, 'lib');
        push @dev => "-D$incdir" if -d $incdir;
    }

    my ($wh, $cfile);
    if ($p->{capture}) {
        ($wh, $cfile) = tempfile("yath-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.out');
        $wh->autoflush(1);
    }

    my (@log, $logfile);
    if ($p->{log}) {
        my $fh;
        ($fh, $logfile) = tempfile("yathlog-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.jsonl');
        close($fh);
        @log = ('--jsonl-file' => $logfile);
        print "DEBUG: log file = '$logfile'\n" if $debug;
    }

    unless ($p->{no_app_path}) {
        push @inc => "-I$apppath" if $cmd =~ m/^(test|start|projects)$/;
        push @dev => "-D$apppath";
    }

    my @cover = cover();

    my $yath = find_yath;
    my @cmd = ($^X, @{$p->{lib}}, @cover, $yath, @{$p->{pre}}, @dev, $cmd ? ($cmd) : (), @inc, @log, @{$p->{cli}});

    print "DEBUG: Command = " . join(' ' => @cmd) . "\n" if $debug;

    return {cmd => \@cmd, wh => $wh, cfile => $cfile, logfile => $logfile};
}

# Spawn the yath command and, when capturing, poll its output file until the
# child is reaped -- escalating to a kill on timeout. Returns ($exit, \@lines).
sub _run_and_capture {
    my ($p, $run, $stdin_fh) = @_;

    my $enc     = $p->{enc};
    my $debug   = $p->{debug};
    my $capture = $p->{capture};

    my $wh    = $run->{wh};
    my $cfile = $run->{cfile};

    my $pid = run_cmd(
        no_set_pgrp => 1,
        $capture ? (stderr => $wh, stdout => $wh) : (),
        $stdin_fh ? (stdin => $stdin_fh) : (),
        command => $run->{cmd},
        run_in_parent => [sub { close($wh) }],
    );

    my (@lines, $exit);
    if ($capture) {
        open(my $rh, '<', $cfile) or die "Could not open output file: $!";
        # Do not apply encoding here — non-blocking reads can split
        # multi-byte characters, corrupting the :utf8 decode.
        $rh->blocking(0);
        my $start = time();
        my $timeout = $ENV{YATH_TESTER_TIMEOUT} // 120;
        while (1) {
            seek($rh, 0, SEEK_CUR); # CLEAR EOF
            my @new = <$rh>;
            push @lines => @new;
            print map { chomp($_); "DEBUG: > $_\n" } @new if $debug > 1;

            waitpid($pid, WNOHANG) or do {
                if ($timeout && time() - $start > $timeout) {
                    $exit = _terminate_timed_out_child($pid);
                    push @lines => "yath tester timeout after ${timeout}s\n";
                    last;
                }
                # Sub-second poll interval. Bare `sleep 0.02` is core integer
                # sleep(0) -- a 100% CPU busy-spin for the child's whole lifetime,
                # multiplied by every concurrent yath() under `prove -j`.
                Time::HiRes::sleep(0.02);
                next;
            };
            $exit = $?;
            last;
        }

        # Child is done — re-read the complete file with proper encoding.
        # This avoids partial multi-byte sequences from non-blocking reads.
        if ($enc) {
            open(my $fh, '<', $cfile) or die "Could not re-open output file: $!";
            apply_encoding($fh, $enc);
            @lines = <$fh>;
            close($fh);
        }
        else {
            seek($rh, 0, SEEK_CUR); # CLEAR EOF
            while (my @new = <$rh>) {
                push @lines => @new;
                print map { chomp($_); "DEBUG: > $_\n" } @new if $debug > 1;
            }
        }
    }
    else {
        print "DEBUG: Waiting for $pid\n" if $debug;
        waitpid($pid, 0);
        $exit = $?;
    }

    print "DEBUG: Exit: $exit\n" if $debug;

    return ($exit, \@lines);
}

# Run the caller-supplied subtest and/or exit check inside a buffered subtest,
# adding a command/output diagnostic when the subtest is not passing.
sub _report_result {
    my ($p, $out, $cmd) = @_;

    my $subtest  = $p->{subtest};
    my $exittest = $p->{exittest};

    return unless $subtest || defined $exittest;

    my $exit = $out->{exit};

    my $name = join(' ', map { length($_) < 30 ? $_ : substr($_, 0, 10) . "[...]" . substr($_, -10) } grep { defined($_) } $p->{prefix}, 'yath', @{$p->{pre}}, $p->{cmd} ? ($p->{cmd}) : (), @{$p->{cli}});
    run_subtest(
        $name,
        sub {
            if (defined $exittest) {
                my $ictx = context(level => 3);
                is($exit, $exittest, "Exit Value Check");
                $ictx->release;
            }

            if ($subtest) {
                local $_ = $out->{output};
                local $? = $out->{exit};
                $subtest->($out);
            }

            my $ictx = context(level => 3);

            $ictx->diag("Command = " . join(' ' => grep { defined $_ } @$cmd) . "\nExit = $exit\n==== Output ====\n$out->{output}\n========")
                unless $ictx->hub->is_passing;

            $ictx->release;
        },
        {buffered => 1},
        $out,
    );
}

# Reap a timed-out yath child. A blocking waitpid() after a lone TERM turns a
# wedged runner that forwards/absorbs SIGTERM into an infinite hang of the
# calling test file. So: send TERM, poll waitpid(WNOHANG) for a short grace
# window, and if the child is still alive escalate to an unconditional KILL
# followed by a (now guaranteed to return) blocking waitpid. Returns the
# child's $? status. `grace` (seconds) is overridable for tests.
sub _terminate_timed_out_child {
    my ($pid, %params) = @_;
    my $grace = $params{grace} // 5;

    kill('TERM', $pid);

    my $deadline = Time::HiRes::time() + $grace;
    while (1) {
        my $got = waitpid($pid, WNOHANG);
        return $? if $got == $pid;    # reaped within the grace window (TERM took)
        return $? if $got < 0;        # already gone / no such child
        last if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.05);
    }

    # TERM did not take within the grace window -- escalate.
    kill('KILL', $pid);
    waitpid($pid, 0);
    return $?;
}

sub _gen_passing_test {
    my ($dir, $subdir, $file) = @_;

    my $path = File::Spec->catdir($dir, $subdir);
    my $full = File::Spec->catfile($path, $file);

    mkdir($path) or die "Could not make $subdir subdir: $!"
        unless -d $path;

    open(my $fh, '>', $full);
    print $fh "use Test2::Tools::Tiny;\nok(1, 'a passing test');\ndone_testing\n";
    close($fh);

    return $full;
}

sub make_example_dir {
    my $dir = tempdir(CLEANUP => 1, TMP => 1);

    _gen_passing_test($dir, 't', 'test.t');
    _gen_passing_test($dir, 't2', 't2_test.t');
    _gen_passing_test($dir, 'xt', 'xt_test.t');

    return $dir;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Tester - Tools for testing yath

=head1 DESCRIPTION

This package provides utilities for running yath from within tests to verify
its behavior. This is primarily used for integration testing of yath and for
third party components.

=head1 SYNOPSIS

    use App::Yath2::Tester qw/yath/;

    my $result = yath(
        # Command and arguments
        command => 'test',
        args    => ['-pMyPlugin', 'path/to/test', ...],

        # Exit code we expect from yath
        exit => 0,

        # Subtest to verify results
        test => sub {
            my $result = shift;

            # Redundant since we have the exit check above
            is($result->{exit}, 0, "Verify exit");

            is($result->{output}, $expected_output, "Got the expected output from yath");
        },
    );

=head1 EXPORTS

There are 2 exports from this module.

=head2 $result = yath(...)

    my $result = yath(
        # Command and arguments
        command => 'test',
        args    => ['-pMyPlugin', 'path/to/test', ...],

        # Exit code we expect from yath
        exit => 0,

        # Subtest to verify results
        test => sub {
            my $result = shift;

            # Redundant since we have the exit check above
            is($result->{exit}, 0, "Verify exit");

            is($result->{output}, $expected_output, "Got the expected output from yath");
        },
    );

=head3 ARGUMENTS

=over 4

=item cmd => $command

=item command => $command

Either 'cmd' or 'command' can be used. This argument takes a string that should
be a command name.

=item cli => \@ARGS

=item args => \@ARGS

Either 'cli' or 'args' can be used. If none are provided an empty arrayref is
used. This argument takes an arrayref of arguments to the yath command.

    $ yath [PRE_COMMAND] [COMMAND] [ARGS]

=item pre => \@ARGS

=item pre_command => \@ARGS

Either 'pre' or 'pre_command' can be used. An empty arrayref is used if none
are provided. These are arguments provided to yath BEFORE the command on the
command line.

    $ yath [PRE_COMMAND] [COMMAND] [ARGS]

=item env => \%ENV

Provide custom environment variable values to set before running the yath
command.

=item encoding => $encoding_name

If you expect your yath command's output to be in a specific encoding you can
specify it here to make sure the C<< $result->{output} >> text has been read
properly.

=item test => sub { ... }

=item tests => sub { ... }

=item subtest => sub { ... }

These 3 arguments are all aliases for the same thing, only one should be used.
The codeblock will be called with C<$result> as the onyl argument. The
codeblock will be run as a subtest. If you specify the C<'exit'> argument that
check will also happen in the same subtest.

    test => sub {
        my $result = shift;

        ... verify result ...
    },

=item exit => $integer

Verify that the yath command exited with the specified exit code. This check
will be run in a subtest. If you specify a custom subtest then this check will
appear to come from that subtest.

=item debug => $integer

Output debug info in realtime, depending on the $integer value this may include
the output from the yath command being run.

    0 - No debugging
    1 - Output the command and other action being taken by the tool
    2 - Echo yath output as it happens

=item inc => $bool

This defaults to true.

When true the tool will look for a directory next to your test file with an
identical name except that '.t' or '.t2' will be stripped from it. If that
directory exists it will be added as a dev-lib to the yath command.

If your test file is 't/foo/bar.t' then your yath command will look like this:

    $ yath -D=t/foo/bar [PRE-COMMAND] [COMMAND] [ARGS]

=item capture => $bool

Defaults to true.

When true the yath output will be captured and put into
C<< $result->{output} >>.

=item log => $bool

Defaults to false.

When true yath will be instructed to produce a log, the log will be accessible
via C<< $result->{log} >>. C<< $result->{log} >> will be an instance of
L<Test2::Harness2::Util::File::JSONL>.

=item stdin => $string_or_handle

Optional STDIN for the yath process. A string is written to a temporary file
and rewound; an already-open filehandle is used as-is. Useful for interactive
mode, where the command's STDIN is passed through to the one running test.

=item no_app_path => $bool

Default to false.

Normally C<< -D=/path/to/lib >> is added to the yath command where
C<'/path/to/lib'> is the path the the lib dir L<App::Yath2> was loaded from.
This normally insures the correct version of yath libraries is loaded.

When this argument is set to true the path is not added.

=item lib => [...]

This poorly named argument allows you to inject command line argumentes between
C<perl> and C<yath> in the command.

    perl [LIB] path/to/yath [PRE-COMMAND] [COMMAND] [ARGS]

=back

=head3 RESULT

The result hashref may containt he following fields depending on the arguments
passed into C<yath()>.

=over 4

=item exit => $integer

Exit value returned from yath.

=item output => $string

The output produced by the yath command.

=item log => $jsonl_object

An instance of L<Test2::Harness2::Util::File::JSONL> opened from the log file
produced by the yath command.

B<Note:> By default no logging is done, you must specify the C<< log => 1 >>
argument to enable it.

=back

=head2 $path = make_example_dir()

This will create a temporary directory with 't', 't2', and 'xt' subdirectories
each of which will contain a single passing test.

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

package App::Yath2::Tester;
use strict;
use warnings;

our $VERSION = '2.000013';

use Test2::API qw/context run_subtest/;
use Test2::Tools::Basic qw/ok/;
use Test2::Tools::Compare qw/is/;

use Carp qw/croak/;
use File::Spec;
use File::Temp qw/tempfile tempdir/;
use POSIX;
use Fcntl qw/SEEK_CUR/;

use App::Yath2::Util qw/find_yath/;
use Test2::Harness2::Util qw/clean_path apply_encoding/;
use Test2::Harness2::Util::File::JSONL;

use Test2::Harness2::Util::IPC qw/start_process swap_io/;

use Importer Importer => 'import';
our @EXPORT    = qw/yath make_example_dir/;
our @EXPORT_OK = qw/tester_ipc_dir/;

my $pdir = tempdir(CLEANUP => 1);

# Accessor for the shared IPC info-file directory that yath() injects via
# YATH_IPC_DIR. Tests that bypass yath() (e.g. raw fork+exec of `yath run`)
# can call this to pin YATH_IPC_DIR in the spawned child, so a `yath start`
# launched via yath() and a sibling `yath run` launched by exec agree on
# where to publish/discover the IPC info file.
sub tester_ipc_dir { return $pdir }

require App::Yath2;
my $apppath = App::Yath2->app_path;

sub cover {
    return unless $ENV{T2_DEVEL_COVER};
    $ENV{T2_COVER_SELF} = 1;
    return '-MDevel::Cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';
}

# Test-side init hook. Only fires when an integration test (or its
# wrapper, t/lib/Test2/Harness2/Test/Yath.pm) has set
# YATH_TESTER_INIT=1 in BEGIN. Outside that env, Tester is inert
# for downstream consumers. The hook lives in t/lib so dev code
# carries no assertion logic.
if ($ENV{YATH_TESTER_INIT}) {
    my $tlib = File::Spec->catdir($apppath, File::Spec->updir, 't', 'lib');
    if (-d $tlib) {
        require lib;
        lib->import($tlib);
        require Test2::Harness2::Test::Init;
    }
}

sub yath {
    my %params = @_;

    my $ctx = context();

    my $p = _yath_extract_params(\%params);

    push @{$p->{lib}} => map { "-I$_" } grep { $_ ne '.' } @INC;

    if (keys %params) {
        croak "Unexpected parameters: " . join (', ', sort keys %params);
    }

    my ($wh, $cfile) = _yath_setup_capture($p->{capture});
    my ($logfile, @log) = _yath_setup_logfile($p->{log}, $p->{debug});

    my @cmd = _yath_build_command($p, \@log);

    print "DEBUG: Command = " . join(" \n" => @cmd) . "\n" if $p->{debug};

    local %ENV = %ENV;
    _yath_setup_env($p->{cmd}, $p->{env});

    my $pid = _yath_spawn(\@cmd, $p->{capture}, $wh);

    local $SIG{ALRM};
    _yath_arm_timeout($p, $pid) if $p->{timeout};

    my $our_pid = $$;
    eval "END{ kill('TERM', \$pid) if \$pid && \$\$ == $our_pid }; 1" or die $@;

    close($wh);

    print "DEBUG: Waiting for $pid\n" if $p->{debug};
    waitpid($pid, 0);
    my $raw_status = $?;
    my $exit = ($raw_status >> 8) & 0xFF;

    my @lines = _yath_read_capture($p->{capture}, $cfile, $p->{encoding}, $p->{debug});

    alarm(0) if $p->{timeout};

    $pid = undef;

    print "DEBUG: Exit: $exit\n" if $p->{debug};

    my $out = {
        exit => $exit,
        $p->{capture} ? (output => join('', @lines))                                          : (),
        $p->{log}     ? (log    => Test2::Harness2::Util::File::JSONL->new(name => $logfile)) : (),
    };

    _yath_run_subtest($p, $out, \@cmd, $exit) if $p->{subtest} || defined $p->{exittest};

    $ctx->release;

    return $out;
}

sub _yath_caller_dev_inc {
    my ($file) = @_;
    my $dir = $file;
    $dir =~ s/\.t2?$//g;
    my $inc = File::Spec->catdir($dir, 'lib');
    return -d $inc ? ("-D$inc") : ();
}

sub _yath_build_command {
    my ($p, $log) = @_;

    my @dev;
    if ($p->{inc}) {
        my (undef, $file) = caller(1);
        push @dev => _yath_caller_dev_inc($file);
    }

    my @inc;
    unless ($p->{no_app_path}) {
        push @inc => "-I$apppath" if $p->{cmd} =~ m/^(test|start|projects)$/;
        push @dev => "-D$apppath";
    }

    my @cover = cover();
    my $yath  = find_yath;

    return ($^X, @{$p->{lib}}, @cover, $yath, @{$p->{pre}}, @dev, $p->{cmd} ? ($p->{cmd}) : (), @inc, @$log, @{$p->{cli}});
}

sub _yath_spawn {
    my ($cmd, $capture, $wh) = @_;

    return start_process $cmd => sub {
        # When this test is itself running under an outer yath, that
        # outer worker sets TMPDIR to a per-worker subdirectory like
        # /tmp/yath-XXXXXXXX/tmp. The spawned inner yath places its
        # IPC::Manager unix-socket route under TMPDIR. The sun_path
        # budget on Linux is only 104 bytes, leaving no room for the
        # 42-byte hashed peer-id under such a deep route, which makes
        # the inner harness fail with "Cannot map peer id ... exceeds
        # available budget". Reset TMPDIR to /tmp here in the spawned
        # child so the inner yath gets a short route. See
        # IPC::Manager::Client::ConnectionUnix::max_on_disk_name_length.
        $ENV{TMPDIR} = '/tmp';
        return unless $capture;
        swap_io(\*STDOUT, $wh);
        swap_io(\*STDERR, $wh);
    };
}

sub _yath_arm_timeout {
    my ($p, $pid) = @_;

    my $timeout_cb = $p->{timeout_cb};
    $SIG{ALRM} = sub {
        $timeout_cb->($pid) if $timeout_cb;
        kill('TERM', $pid);
    };

    alarm($p->{timeout});
}

sub _yath_extract_params {
    my ($params) = @_;

    my %p;
    $p{cmd}         = delete $params->{cmd} // delete $params->{command};
    $p{cli}         = delete $params->{cli} // delete $params->{args} // [];
    $p{pre}         = delete $params->{pre} // delete $params->{pre_command} // [];
    $p{env}         = delete $params->{env} // {};
    $p{encoding}    = delete $params->{encoding};
    $p{prefix}      = delete $params->{prefix};
    $p{timeout}     = delete $params->{timeout};
    $p{timeout_cb}  = delete $params->{timeout_cb};
    $p{subtest}     = delete $params->{test} // delete $params->{tests} // delete $params->{subtest};
    $p{exittest}    = delete $params->{exit};
    $p{debug}       = delete $params->{debug}   // 0;
    $p{inc}         = delete $params->{inc}     // 1;
    $p{capture}     = delete $params->{capture} // 1;
    $p{log}         = delete $params->{log}     // 0;
    $p{no_app_path} = delete $params->{no_app_path};
    $p{lib}         = delete $params->{lib} // [];

    return \%p;
}

sub _yath_setup_capture {
    my ($capture) = @_;
    return (undef, undef) unless $capture;

    my ($wh, $cfile) = tempfile("yath-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.out');
    $wh->autoflush(1);

    return ($wh, $cfile);
}

sub _yath_setup_logfile {
    my ($log, $debug) = @_;
    return (undef) unless $log;

    my $logdir = tempdir("yathlogs-$$-XXXXXXXX", TMPDIR => 1, CLEANUP => 1);
    my $logfile = File::Spec->catfile($logdir, "run.yath");
    my @log = ('--log-file' => $logfile);
    print "DEBUG: log file = '$logfile'\n" if $debug;

    return ($logfile, @log);
}

sub _yath_setup_env {
    my ($cmd, $env) = @_;

    $ENV{YATH_IPC_DIR} = $pdir;
    $ENV{YATH_CMD} = $cmd;
    $ENV{NESTED_YATH} = 1;
    $ENV{T2_HARNESS_PROC_PREFIX} = "nested";
    $ENV{'YATH_SELF_TEST'} = 1;
    # Pin the spawned yath's @INC: App::Yath::Script::do_begin's
    # inject_includes() will splat @INC from this list before the V2
    # require, so a stale CPAN install can't outrace our in-tree
    # lib/App/Yath/Script/V2.pm via Perl's default search path.
    # Append rather than clobber so a caller-set T2_HARNESS_INCLUDES
    # (used e.g. by t/Yath/integration/nested_includes.t to inject
    # paths into the spawned test child's @INC) survives.
    {
        my $tester_inc = join ';' => $apppath, grep { $_ ne '.' } @INC;
        my $caller_inc = $ENV{T2_HARNESS_INCLUDES};
        $ENV{T2_HARNESS_INCLUDES} = (defined $caller_inc && length $caller_inc)
            ? "$caller_inc;$tester_inc"
            : $tester_inc;
    }
    $ENV{$_} = $env->{$_} for keys %$env;
    $ENV{YATH_COLOR} = 0;
}

sub _yath_read_capture {
    my ($capture, $cfile, $enc, $debug) = @_;
    return () unless $capture;

    open(my $rh, '<', $cfile) or die "Could not open output file: $!";
    apply_encoding($rh, $enc) if $enc;
    my @lines = <$rh>;
    print map { chomp($_); "DEBUG: > $_\n" } @lines if $debug > 1; ## no critic

    return @lines;
}

sub _yath_run_subtest {
    my ($p, $out, $cmd, $exit) = @_;

    my $prefix   = $p->{prefix};
    my $pre      = $p->{pre};
    my $cli      = $p->{cli};
    my $subtest  = $p->{subtest};
    my $exittest = $p->{exittest};

    my $name = join(' ', map { length($_) < 30 ? $_ : substr($_, 0, 10) . "[...]" . substr($_, -10) } grep { defined($_) } $prefix, 'yath', @$pre, $p->{cmd} ? ($p->{cmd}) : (), @$cli);
    run_subtest(
        $name,
        sub {
            if (defined $exittest) {
                my $ictx = context(level => 3);
                if (ref $exittest eq 'CODE') {
                    ok($exittest->($exit), "Exit Value Check (coderef)");
                }
                else {
                    is($exit, $exittest, "Exit Value Check");
                }
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

C<yath> and C<make_example_dir> are exported by default. C<tester_ipc_dir>
is exportable on request.

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

When true yath will be run with C<--log-file> pointing to a temporary
C<.yath> archive so that the full run log is preserved after the process
exits. The archive path is accessible via C<< $result->{log}->name >>.
C<< $result->{log} >> is an instance of L<Test2::Harness2::Util::File::JSONL>
used as a thin wrapper that exposes the path via C<< ->name >>; pass that
path to L<App::Yath2::Log> to read events.

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

=item log => $workdir_object

Present when C<< log => 1 >> was passed. An instance of
L<Test2::Harness2::Util::File::JSONL> wrapping a temporary C<.yath> archive
path. Call C<< $result->{log}->name >> to get the archive path, then pass it
to L<App::Yath2::Log> to parse run events.

B<Note:> By default no workdir is kept, you must specify the C<< log => 1 >>
argument to enable it.

=back

=head2 $path = make_example_dir()

This will create a temporary directory with 't', 't2', and 'xt' subdirectories
each of which will contain a single passing test.

=head2 $dir = tester_ipc_dir()

Return the shared IPC info-file directory that L</yath> injects via
C<YATH_IPC_DIR>. Tests that bypass L</yath> (e.g. raw fork+exec of
C<yath run>) call this to pin C<YATH_IPC_DIR> in the spawned child,
so a C<yath start> launched via L</yath> and a sibling C<yath run>
launched by exec agree on where to publish and discover the IPC
info file.

=head2 Private helpers

=over 4

=item _yath_extract_params

Pull the recognized named arguments out of the C<yath()> C<%params>
hash into a flat C<\%p> structure, applying the same defaults and
aliases (C<cmd>/C<command>, C<cli>/C<args>, ...) as before.

=item _yath_setup_capture

Allocate the temp output file used to capture child STDOUT/STDERR when
C<capture> is enabled; returns C<($wh, $cfile)> or C<(undef, undef)>.

=item _yath_setup_logfile

Allocate the temp C<--log-file> path when C<log> is enabled; returns
C<($logfile, @log_args)> or C<(undef)>.

=item _yath_caller_dev_inc

Derive the per-test C<-D=/path/to/lib> arg from a caller's filename
(strip C<.t>/C<.t2>, look for a sibling C<lib/> directory).

=item _yath_build_command

Assemble the full child command line (perl, lib args, yath, pre-args,
dev libs, command, includes, log args, cli args).

=item _yath_setup_env

Mutate C<%ENV> in place to set the C<YATH_*>/C<NESTED_YATH>/
C<T2_HARNESS_INCLUDES> variables the spawned yath expects. Caller is
responsible for the C<local %ENV>.

=item _yath_spawn

C<start_process> the child with a post-fork callback that pins
C<TMPDIR> to C</tmp> and swaps STDOUT/STDERR to the capture handle.

=item _yath_arm_timeout

Install the C<$SIG{ALRM}> handler and C<alarm()> for the configured
C<timeout>, optionally invoking the user-supplied C<timeout_cb> before
TERMing the child.

=item _yath_read_capture

Read the captured output file back, applying the requested encoding and
echoing each line under C<< debug > 1 >>; returns the list of lines.

=item _yath_run_subtest

Emit the C<run_subtest> wrapper around C<exit>/C<test> checks and the
fail-only command/output diagnostic.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

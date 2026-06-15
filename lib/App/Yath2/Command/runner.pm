package App::Yath2::Command::runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use Config qw/%Config/;
use File::Spec;

# For some reason Filter::Util::Class breaks the STDIN filehandle. This works
# around that.
my $FIX_STDIN;

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

use Carp qw/confess/;
use Scalar::Util qw/openhandle/;
use List::Util qw/first/;
use File::Path qw/remove_tree/;

use Scope::Guard;

use Test2::Util qw/clone_io/;

use Long::Jump qw/setjump longjump/;

use Getopt::Yath::Settings;

use Test2::Harness2::Util qw/mod2file write_file_atomic open_file clean_path process_includes/;

use Test2::Harness2::Util::IPC qw/swap_io/;

use Test2::Harness2::Runner::Preloader();

my @SIGNALS = grep { $_ ne 'ZERO' } split /\s+/, $Config{sig_name};

# If FindBin is installed, go ahead and load it. We do not care much about
# success vs failure here.
BEGIN {
    local $@;
    eval { require FindBin; FindBin->import };
}

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

sub internal_only { 1 }
sub summary       { "For internal use only" }
sub name          { 'runner' }

sub init { confess(ref($_[0]) . " is not intended to be instantiated") }
sub run  { confess(ref($_[0]) . " does not implement run()") }

our $RUNNER_PID;

sub generate_run_sub {
    my $class = shift;
    my ($symbol, $argv, $spawn_settings) = @_;
    my ($dir, %args) = @$argv;

    $RUNNER_PID = $$;
    my $runner_pid = $$;
    my $settings   = Getopt::Yath::Settings->FROM_JSON_FILE(File::Spec->catfile($dir, 'settings.json'));

    my $name = $ENV{NESTED_YATH} ? 'yath-nested-runner' : 'yath-runner';
    $name = $settings->debug->procname_prefix . "-${name}" if $settings->debug->procname_prefix;
    $0    = $name;

    my $cleanup = $class->cleanup($settings, \%args, $dir);

    my $jump = setjump "Test-Runner" => sub {
        local $.;

        my %orig_sig = %SIG;
        my $guard    = Scope::Guard->new(sub {
            my %seen;
            for my $sig (@SIGNALS) {
                next if $seen{$sig}++;
                if (exists $orig_sig{$sig}) {
                    $SIG{$sig} = $orig_sig{$sig};
                }
                else {
                    delete $SIG{$sig};
                }
            }
        });

        require Test2::Harness2::Runner;
        my $runner = Test2::Harness2::Runner->new(
            $settings->runner->all,

            %args,

            dir      => $dir,
            settings => $settings,

            fork_job_callback       => sub { $class->launch_via_fork(@_) },
            fork_spawn_callback     => sub { $class->launch_spawn(@_) },
            respawn_runner_callback => sub { return unless $$ == $runner_pid; longjump "Test-Runner" => 'respawn' },
        );

        my $exit = $runner->process();

        if ($$ == $runner_pid) {
            $_->cleanup() for @{$runner->state->resources};
        }

        my $complete = File::Spec->catfile($dir, 'complete');
        write_file_atomic($complete, '1');

        exit($exit // 1);
    };

    die "Test runner completed, but failed to exit" unless $jump;

    my ($action, $job, $stage) = @$jump;

    if ($action eq 'respawn') {
        print "$$ Respawning the runner...\n";
        $cleanup->dismiss(1);
        exec($^X, $settings->harness->script, @{$spawn_settings->harness->orig_argv});
        warn "exec failed!";
        exit 1;
    }

    die "Invalid action: $action" if $action ne 'run_test';

    if (my $chdir = $job->ch_dir) {
        chdir($chdir) or die "Could not chdir: $!";
    }
    goto::file->import($job->run_file);
    $class->cleanup_process($job, $stage);
    DB::enable_profile() if $settings->runner->nytprof;
}

sub cleanup {
    my $class = shift;
    my ($settings, $args, $dir) = @_;

    my $pfile = $args->{persist} or return;

    my $pid = $$;
    return Scope::Guard->new(sub {
        return unless $pid == $$;

        unlink($pfile);

        remove_tree($dir, {safe => 1, keep_root => 0}) unless $settings->debug->keep_dirs;
    });
}

sub get_stage {
    my $class = shift;
    my ($runner) = @_;

    return unless $runner->can('stage');

    my $stage_name = $runner->stage     or return;
    my $preloader  = $runner->preloader or return;
    my $p          = $preloader->staged or return;

    return $p->stage_lookup->{$stage_name};
}

sub launch_spawn {
    my $class = shift;
    my ($runner, $spawn) = @_;

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
        $pid = $class->launch_via_fork($runner, $spawn);

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

sub launch_via_fork {
    my $class = shift;
    my ($runner, $job) = @_;

    my $stage = $class->get_stage($runner);

    $stage->do_pre_fork($job) if $stage;

    my $pid = fork();
    die "Failed to fork: $!" unless defined $pid;

    # In parent
    return $pid if $pid;

    # In Child: this process becomes the Test2-Collector collector PARENT. The
    # collector forks the actual test child internally; that child runs the
    # run_sub below, which unwinds back to the Test-Runner setjump (in
    # generate_run_sub) and goto::file's in the real test -- so the test still
    # runs in-process with everything preloaded, but now under the collector's
    # stream formatter, and its full event stream is recorded to
    # events.jsonl.zst.
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
            longjump "Test-Runner" => ('run_test', $job, $stage);
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
                # and resume the harness's own launch path, which goto::file's
                # the test in-process.
                $guard->dismiss;
                $stage->do_post_fork($job) if $stage;
                longjump "Test-Runner" => ('run_test', $job, $stage);
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

sub cleanup_process {
    my $class = shift;
    my ($job, $stage) = @_;

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

sub test2_state {
    my $class = shift;
    my ($job) = @_;

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

sub final_state {
    my $class = shift;
    my ($job) = @_;

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

sub do_loads {
    my $class = shift;
    my ($job) = @_;

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

sub build_init_state {
    my $class = shift;
    my ($job) = @_;

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

sub set_env {
    my $class = shift;
    my ($job) = @_;

    my $env = $job->env_vars;
    {
        no warnings 'uninitialized';
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    $ENV{T2_HARNESS_FORKED}  = 1;
    $ENV{T2_HARNESS_PRELOAD} = 1;

    return;
}

sub update_io {
    my $class = shift;
    my ($job) = @_;

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
sub _reset_DATA {
    my $class = shift;

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
sub preload_list {
    my $class = shift;

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

App::Yath2::Command::runner - For internal use only

=head1 DESCRIPTION

No Description

=head1 USAGE

    $ yath [YATH OPTIONS] runner [OPTIONS]

=head2 OPTIONS

=head3 Plugins

=over 4

=item --no-scan-plugins

=item --no-no-scan-plugins

Normally yath scans for and loads all App::Yath2::Plugin::* modules in order to bring in command-line options they may provide. This flag will disable that. This is useful if you have a naughty plugin that is loading other modules when it should not.


=item -pPLUGIN

=item --plugin PLUGIN

=item --plugins PLUGIN

=item --plugin PLUGIN=arg1,arg2,...

=item --plugins PLUGIN=arg1,arg2,...

=item --plugin +App::Yath2::Plugin::PLUGIN

=item --plugins +App::Yath2::Plugin::PLUGIN

=item --no-plugins

Load a yath plugin.

Note: Can be specified multiple times


=back

=head3 Environment

=over 4

=item --persist-dir ARG

=item --persist-dir=ARG

=item --no-persist-dir

Where to find persistence files.


=item --pfile ARG

=item --pfile=ARG

=item --persist-file ARG

=item --persist-file=ARG

=item --no-persist-file

Where to find the persistence file. The default is /{system-tempdir}/project-yath-persist.json. If no project is specified then it will fall back to the current directory. If the current directory is not writable it will default to /tmp/yath-persist.json which limits you to one persistent runner on your system.


=item --project ARG

=item --project=ARG

=item --project-name ARG

=item --project-name=ARG

=item --no-project

This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file. This is necessary for a persistent runner.


=back

=head3 Developer

=over 4

=item -D

=item -Dlib

=item -D=lib

=item --dev-lib

=item --dev-lib=lib

=item --no-dev-lib

Add paths to @INC before loading ANYTHING. This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.

Note: Can be specified multiple times


=back

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

=head3 Cover Options

=over 4

=item --cover-agg ByRun

=item --cover-agg ByTest

=item --cover-aggregator ByRun

=item --cover-aggregator ByTest

=item --cover-agg +Custom::Aggregator

=item --cover-aggregator +Custom::Aggregator

=item --no-cover-aggregator

Choose a custom aggregator subclass


=item --cover-class ARG

=item --cover-class=ARG

=item --no-cover-class

Choose a Test2::Plugin::Cover subclass


=item --cover-dir ARG

=item --cover-dir=ARG

=item --cover-dirs ARG

=item --cover-dirs=ARG

=item --cover-dir '["json","list"]'

=item --cover-dir='["json","list"]'

=item --cover-dirs '["json","list"]'

=item --cover-dirs='["json","list"]'

=item --no-cover-dirs

NO DESCRIPTION - FIX ME

Note: Can be specified multiple times


=item --cover-exclude-private

=item --no-cover-exclude-private




=item --cover-files

=item --no-cover-files

Use Test2::Plugin::Cover to collect coverage data for what files are touched by what tests. Unlike Devel::Cover this has very little performance impact (About 4% difference)


=item --cover-from path/to/log.jsonl

=item --cover-from path/to/coverage.jsonl

=item --cover-from http://example.com/coverage

=item --no-cover-from

This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will not be run if the file/url is invalid.


=item --cover-from-type log

=item --cover-from-type json

=item --cover-from-type jsonl

=item --no-cover-from-type

File type for coverage source. Usually it can be detected, but when it cannot be you should specify. "json" is old style single-blob coverage data, "jsonl" is the new by-test style, "log" is a logfile from a previous run.


=item --cover-manager My::Coverage::Manager

=item --no-cover-manager

Coverage 'from' manager to use when coverage data does not provide one


=item --cover-maybe-from path/to/log.jsonl

=item --cover-maybe-from path/to/coverage.jsonl

=item --cover-maybe-from http://example.com/coverage

=item --no-cover-maybe-from

This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will coninue if even if the coverage file/url is invalid.


=item --cover-maybe-from-type log

=item --cover-maybe-from-type json

=item --cover-maybe-from-type jsonl

=item --no-cover-maybe-from-type

Same as "from_type" but for "maybe_from". Defaults to "from_type" if that is specified, otherwise auto-detect


=item --cover-metrics

=item --no-cover-metrics




=item --cover-type ARG

=item --cover-type=ARG

=item --cover-types ARG

=item --cover-types=ARG

=item --cover-type '["json","list"]'

=item --cover-type='["json","list"]'

=item --cover-types '["json","list"]'

=item --cover-types='["json","list"]'

=item --no-cover-types

NO DESCRIPTION - FIX ME

Note: Can be specified multiple times


=item --cover-write

=item --cover-write=coverage.json

=item --cover-write=coverage.jsonl

=item --no-cover-write

Create a json or jsonl file of all coverage data seen during the run (This implies --cover-files).


=back

=head3 Git Options

=over 4

=item --git-change-base HEAD^

=item --git-change-base master

=item --git-change-base df22abe4

=item --no-git-change-base

Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.


=back

=head3 Notification Options

=over 4

=item --notify-email foo@example.com

=item --no-notify-email

Email the test results to the specified email address(es)

Note: Can be specified multiple times


=item --notify-email-fail foo@example.com

=item --no-notify-email-fail

Email failing results to the specified email address(es)

Note: Can be specified multiple times


=item --notify-email-from foo@example.com

=item --no-notify-email-from

If any email is sent, this is who it will be from


=item --notify-email-owner

=item --no-notify-email-owner

Email the owner of broken tests files upon failure. Add `# HARNESS-META-OWNER foo@example.com` to the top of a test file to give it an owner


=item --notify-no-batch-email

=item --no-notify-no-batch-email

Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.


=item --notify-no-batch-slack

=item --no-notify-no-batch-slack

Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.


=item --notify-slack '#foo'

=item --notify-slack '@bar'

=item --no-notify-slack

Send results to a slack channel and/or user

Note: Can be specified multiple times


=item --notify-slack-fail '#foo'

=item --notify-slack-fail '@bar'

=item --no-notify-slack-fail

Send failing results to a slack channel and/or user

Note: Can be specified multiple times


=item --notify-slack-owner

=item --no-notify-slack-owner

Send slack notifications to the slack channels/users listed in test meta-data when tests fail.


=item --notify-slack-url https://hooks.slack.com/...

=item --no-notify-slack-url

Specify an API endpoint for slack webhook integrations


=item --notify-msg ARG

=item --notify-msg=ARG

=item --notify-text ARG

=item --notify-text=ARG

=item --notify-message ARG

=item --notify-message=ARG

=item --no-notify-text

Add a custom text snippet to email/slack notifications


=item --notify-text-module ARG

=item --notify-text-module=ARG

=item --notify-message-module ARG

=item --notify-message-module=ARG

=item --no-notify-text-module

Use the specified module to generate messages for emails and/or slack.


=back

=head3 YathUI Options

=over 4

=item --yathui-api-key ARG

=item --yathui-api-key=ARG

=item --no-yathui-api-key

Yath-UI API key. This is not necessary if your Yath-UI instance is set to single-user


=item --yathui-coverage

=item --no-yathui-coverage

Poll coverage data from Yath-UI to determine what tests should be run for changed files


=item --yathui-durations

=item --no-yathui-durations

Poll duration data from Yath-UI to help order tests efficiently


=item --yathui-grace

=item --no-yathui-grace

If yath cannot connect to yath-ui it normally throws an error, use this to make it fail gracefully. You get a warning, but things keep going.


=item --yathui-long-duration 10

=item --no-yathui-long-duration

Minimum duration length (seconds) before a test goes from MEDIUM to LONG


=item --yathui-medium-duration 5

=item --no-yathui-medium-duration

Minimum duration length (seconds) before a test goes from SHORT to MEDIUM


=item --yathui-mode qvf

=item --yathui-mode qvfd

=item --yathui-mode summary

=item --yathui-mode complete

=item --no-yathui-mode

Set the upload mode (default 'qvfd')


=item --yathui-project ARG

=item --yathui-project=ARG

=item --no-yathui-project

The Yath-UI project for your test results


=item --yathui-retry

=item --yathui-retry=COUNT

=item --no-yathui-retry

How many times to try an operation before giving up

Note: Can be specified multiple times, counter bumps each time it is used.


=item --yathui-upload

=item --no-yathui-upload

Upload the log to Yath-UI


=item --yathui-url http://my-yath-ui.com/...

=item --yathui-uri http://my-yath-ui.com/...

=item --no-yathui-url

Yath-UI url


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

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut


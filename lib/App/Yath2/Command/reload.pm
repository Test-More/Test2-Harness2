package App::Yath2::Command::reload;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();

use App::Yath2::Pfile;
use Getopt::Yath::Settings();

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

sub group { 'persist' }

sub summary { "Reload the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
Sends a SIGHUP to the persistent runner and clears the module blacklist. On a
runner with preload stages the runner routes the signal to its base stage, which
respawns the whole preload tree ASYNCHRONOUSLY -- the command returns as soon as
the signal is delivered, it does NOT wait for the stages to come back up (use
'yath status' to watch them). On a runner with NO preload stages there is nothing
to reload: SIGHUP is a no-op, so the command warns and exits 2 instead of falsely
reporting success.
    EOT
}

# NOTE (deferred fork B, gated on #113 -- see also the #159 premise conflict about
# _preload_root_stage_identity's pid comparison): the truthful "which stages
# actually reloaded" fix must route through the runner socket as a two-way
# request/response instead of the raw kill('HUP') below, tighten exit 0 to ">=1
# stage confirmed respawned back to 'up'", and poll runner status until the
# previously-up stages report a newer stamp. That runner-side handler MUST be named
# `trigger_reload` -- the name `reload` is already taken by the one-way stage->runner
# monitor notification (request_handler_reload), and a command frame named `reload`
# would corrupt reload_state. Not implemented here (fork A only).
sub run {
    my $self = shift;

    my $pfile = App::Yath2::Pfile->find($self->settings)
        or die "Could not find a persistent yath running.\n";

    my $data = $pfile->data;

    # A live socket with a missing/garbled workdir PID file (external deletion or
    # corruption only -- the PID is written before the socket binds, so this is not a
    # boot race) used to crash with "Can't kill a non-numeric process ID" after
    # printing "Sending SIGHUP to <blank>". Guard it with an actionable message (#146).
    my $pid = $data->{pid}
        // die "Runner found at $data->{dir} but its PID file is missing/unreadable; restart the runner.\n";

    # No-preload gate: a runner with no preload stages cannot reload -- its SIGHUP
    # handler is an explicit no-op -- so telling the user "success" is a lie. Detect
    # it by reading the runner workdir's settings.json (written by `yath start`, and
    # the runner's own canonical boot input), which carries runner.preloads. A live
    # runner always has this file; treat its absence as a fault, not silent success.
    my $sfile = File::Spec->catfile($data->{dir}, 'settings.json');
    my $rsettings;
    my $ok = eval { $rsettings = Getopt::Yath::Settings->FROM_JSON_FILE($sfile); 1 };
    my $err = $@;
    unless ($ok) {
        print STDERR "Could not read the runner's settings file '$sfile': $err";
        return 1;
    }

    my $preloads = $rsettings->check_group('runner') ? ($rsettings->runner->preloads // []) : [];
    unless (@$preloads) {
        print STDERR "This persistent runner has no preload stages, so there is nothing to reload; SIGHUP is a no-op.\n"
                   . "Restart the runner ('yath stop' then 'yath start') to pick up code changes.\n";
        return 2;
    }

    my $blacklist = File::Spec->catfile($data->{dir}, 'BLACKLIST');
    if (-e $blacklist) {
        print "Deleting module blacklist...\n";
        unlink($blacklist) or warn "Could not delete blacklist file!";
    }

    print "\nSending SIGHUP to $pid\n\n";
    unless (kill('HUP', $pid)) {
        print STDERR "Could not send SIGHUP to $pid: $!\n";
        return 1;
    }

    print "Reload requested (SIGHUP sent to pid $pid). The preload tree respawns\n"
        . "asynchronously; use 'yath status' to watch the stages come back up.\n";
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::reload - Reload the persistent test runner

=head1 DESCRIPTION

This sends a SIGHUP to the persistent runner and clears the module blacklist
(allowing all preloads to load as normal).

On a runner that has preload stages, the runner routes the signal to its base
stage, which respawns the whole preload tree B<asynchronously>. The command
returns as soon as the signal is delivered -- it does B<not> wait for the stages
to finish respawning. Use C<yath status> to watch the stages come back up.

On a runner that has B<no> preload stages there is nothing to reload: the SIGHUP
handler is an explicit no-op. Rather than falsely report success, the command
prints a warning and exits 2; restart the runner (C<yath stop> then
C<yath start>) to pick up code changes.

=head1 EXIT CODES

=over 4

=item 0

Reload dispatched: the runner has preload stages, the blacklist was cleared, and
the SIGHUP was delivered. Note this means the reload was B<requested>, not
completed -- the preload tree respawns asynchronously.

=item 1

Failure: the runner was found but the reload could not be delivered -- the
C<kill('HUP', ...)> failed, or the runner's C<settings.json> was missing or
unreadable (a live runner always has one, so its absence is treated as a fault,
never as silent success).

=item 2

Nothing to reload: the runner has no preload stages. The warning and restart
instruction are printed.

=item 255

No persistent runner was found (shared with the other C<persist> commands).

=back


=head1 USAGE

    $ yath [YATH OPTIONS] reload [OPTIONS]

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

Where to find the persistent runner discovery symlink (a link to the runner's socket). The default is /{system-tempdir}/.project-yath-runner.sock. If no project is specified it falls back to the current directory; if the current directory is not writable it defaults to the system temp dir, which limits you to one persistent runner per project on your system.


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


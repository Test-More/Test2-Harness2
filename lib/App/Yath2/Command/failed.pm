package App::Yath2::Command::failed;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Util::Table qw/table/;

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase qw{<log_file};

use Getopt::Yath;

# POD documents that 'failed' accepts the same renderer/formatter options as
# 'test'. Getopt::Yath instances are per-package (unlike 1.0's global option
# registry), so pull the Display group in explicitly to honor that contract.
include_options('App::Yath2::Options::Display');

option_group {group => 'display', category => 'Display Options'} => sub {
    option brief => (
        type        => 'Bool',
        description => 'Show only the files that failed, newline separated, no other output. If a file failed once but passed on a retry it will NOT be shown.',
    );
};

sub summary { "Show the failed tests from an event log" }

sub group { 'log' }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] [job1, job2, ...]" }

sub description {
    return <<"    EOT";
This yath command will list the test scripts from an event log that have failed.
The only required argument is the path to the log file, which may be compressed.
Any extra arguments are assumed to be job id's. If you list any jobs,
only the listed jobs will be processed.

This command accepts all the same renderer/formatter options that the 'test'
command accepts.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    $self->{+LOG_FILE} = $self->shift_log_file_arg;

    my %failed;
    $self->each_log_event(sub {
        my ($job_id, $f) = @_;

        push @{$failed{$job_id}->{subtests}} => $self->subtests($f)
            if $f->{parent} && !$f->{trace}->{nested} && $self->include_subtest($f);

        return unless $f->{harness_job_end};
        return unless $f->{harness_job_end}->{fail} || $failed{$job_id};

        push @{$failed{$job_id}->{ends}} => $f->{harness_job_end};
    });

    my $rows = [];
    while (my ($job_id, $data) = each %failed) {
        my $ends = $data->{ends} // [];

        # A failing job from an interrupted run (Ctrl-C, CI cancellation, OOM
        # kill) can be recorded here via a failing subtest but never emit a
        # harness_job_end, leaving @$ends empty. Guard the -1 deref: reaching
        # into $ends->[-1]->{...} on an empty array autovivifies subscript -1
        # and dies with "Modification of non-creatable array value attempted,
        # subscript -1" -- crashing the very command used to inspect the logs
        # of an aborted run. The brief 'if' condition (line 87) triggered it too.
        my $end = @$ends ? $ends->[-1] : undef;

        my %seen;
        my $subtests = join "\n" => grep { !$seen{$_}++ } sort @{$data->{subtests} // []};

        if ($settings->display->brief) {
            print $end->{rel_file}, "\n" if defined($end) && $end->{fail};
        }
        else {
            my $rel_file  = defined($end) ? $end->{rel_file} : 'N/A';
            my $succeeded = defined($end) && !$end->{fail} ? "YES" : "NO";
            push @$rows => [$job_id, scalar(@$ends), $rel_file, $subtests, $succeeded];
        }
    }

    return 0 if $settings->display->brief;

    unless (@$rows) {
        print "\nNo jobs failed!\n";
        return 0;
    }

    print "\nThe following jobs failed at least once:\n";
    print join "\n" => table(
        collapse => 1,
        header   => ['Job ID', 'Times Run', 'Test File', "Subtests", "Succeeded Eventually?"],
        rows     => $rows,
    );
    print "\n";

    return 0;
}

sub include_subtest {
    my $self = shift;
    my ($f) = @_;

    return 0 unless $f->{parent} && keys %{$f->{parent}};
    return 0 if $f->{assert}->{pass} || !keys %{$f->{assert}};
    return 0 if $f->{amnesty} && @{$f->{amnesty}};
    return 1;
}

sub subtests {
    my $self = shift;
    my ($f, $prefix) = @_;

    return unless $self->include_subtest($f);

    my $name = $f->{assert}->{details};
    unless ($name) {
        my $frame = $f->{trace}->{frame};
        $name = "Unnamed Subtest";
        $name .= " ($frame->[1] line $frame->[2])" if $frame->[1] && $frame->[2];
    }

    $name = "$prefix -> $name" if $prefix;

    my @out;
    push @out => $name;
    for my $child (@{$f->{parent}->{children}}) {
        next unless $child->{parent};
        push @out => $self->subtests($child, $name);
    }

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::failed - Show the failed tests from an event log

=head1 DESCRIPTION

This yath command will list the test scripts from an event log that have failed.
The only required argument is the path to the log file, which may be compressed.
Any extra arguments are assumed to be job id's. If you list any jobs,
only the listed jobs will be processed.

This command accepts all the same renderer/formatter options that the 'test'
command accepts.


=head1 USAGE

    $ yath [YATH OPTIONS] failed [OPTIONS]

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

=head3 Display Options

=over 4

=item --brief

=item --no-brief

Show only the files that failed, newline separated, no other output. If a file failed once but passed on a retry it will NOT be shown.


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


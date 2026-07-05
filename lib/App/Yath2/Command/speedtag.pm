package App::Yath2::Command::speedtag;
use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

our $VERSION = '2.000000';

use Getopt::Yath;

use Cwd qw/getcwd/;

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase qw/-log_file -max_short -max_medium/;
use Test2::Harness2::Util qw/clean_path/;
use Test2::Harness2::Runner::Constants qw/DURATION_MAX_SHORT DURATION_MAX_MEDIUM/;

include_options(
    'App::Yath2::Options::Debug',
);

option_group {group => 'speedtag', category => 'speedtag options'} => sub {
    option generate_durations_file => (
        type        => 'Auto',
        autofill    => 1,
        alt         => ['durations', 'duration'],
        description => "Write out a duration json file, if no path is provided 'duration.json' will be used. The .json extension is added automatically if omitted.",

        long_examples => ['', '=/path/to/durations.json'],

        normalize => \&normalize_duration,

        # action -> trigger: fires BEFORE add_value. Resolve the '1' sentinel
        # (bare --generate-durations-file) to the default 'durations.json'.
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';
            for my $val (@{$params{val}}) {
                next unless $val eq '1';
                $val = clean_path('durations.json');
            }
        },
    );

    option pretty => (
        type        => 'Bool',
        description => "Generate a pretty 'durations.json' file when combined with --generate-durations-file. (sorted and multilines)",
        default     => 0,
    );
};

sub group { 'log' }

sub summary { "Tag tests with duration (short medium long) using a source log" }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] max_short_duration_seconds max_medium_duration_seconds" }

sub description {
    return <<"    EOT";
This command will read the test durations from a log and tag/retag all tests
from the log based on the max durations for each type.
    EOT
}

sub init {
    my $self = shift;

    # Share the runner's SHORT/MEDIUM thresholds so the tagger and the scheduler
    # (TestFile.pm, TODO-118) agree on the same second-count cutoffs.
    $self->{+MAX_SHORT}  //= DURATION_MAX_SHORT;
    $self->{+MAX_MEDIUM} //= DURATION_MAX_MEDIUM;
}

sub normalize_duration {
    my $val = shift;

    return $val if $val eq '1';

    $val =~ s/\.json$//g;
    $val .= '.json';

    return clean_path($val);
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    my $initial_dir = clean_path(getcwd());

    $self->{+LOG_FILE} = $self->shift_log_file_arg;

    $self->{+MAX_SHORT}  = shift @$args if @$args;
    $self->{+MAX_MEDIUM} = shift @$args if @$args;

    die "max short duration must be an integer, got '$self->{+MAX_SHORT}'"  unless $self->{+MAX_SHORT}  && $self->{+MAX_SHORT}  =~ m/^\d+$/;
    die "max medium duration must be an integer, got '$self->{+MAX_MEDIUM}'" unless $self->{+MAX_MEDIUM} && $self->{+MAX_MEDIUM} =~ m/^\d+$/;

    my $durations_file = $self->settings->speedtag->generate_durations_file;
    my %durations;

    $self->each_job_end(sub {
        my ($job_id, $end) = @_;

        # Test2-Collector's TimeTracker records the phase totals directly as the
        # harness_job_end `times` hash; `total` is the wall duration. (The
        # pre-swap shape nested this under times->{totals}->{total}.)
        my $file = $end->{file}  ? clean_path($end->{file}) : undef;
        my $time = $end->{times} ? $end->{times}->{total}   : undef;

        return unless $file && $time;

        my $dur = $self->classify_duration($time);

        # tag_file does a non-atomic-safe rewrite (sibling tempfile + rename);
        # on any read/write failure it warns, leaves the original untouched, and
        # returns false so we skip the 'Tagged' line + durations entry.
        return unless $self->tag_file($file, $dur);

        if ($durations_file) {
            my $tfile = $file;
            $tfile =~ s{^\Q$initial_dir\E/+}{};
            $durations{$tfile} = uc($dur);
        }

        print "Tagged '$dur': $file\n";
    });

    if ($durations_file) {
        my $jfile = Test2::Harness2::Util::File::JSON->new(name => $durations_file, pretty => $self->settings->speedtag->pretty);
        $jfile->write(\%durations);
    }

    return 0;
}

# Bucket a wall-duration (seconds) into short/medium/long using the runner's
# shared SHORT/MEDIUM cutoffs.
sub classify_duration {
    my $self = shift;
    my ($seconds) = @_;

    return 'short'  if $seconds < $self->{+MAX_SHORT};
    return 'medium' if $seconds < $self->{+MAX_MEDIUM};
    return 'long';
}

# Read $file, inject/replace its HARNESS-DURATION header for class $dur, and
# atomically rewrite it. Returns true on a successful rewrite; false (with a
# warning) if the file could not be read or written.
sub tag_file {
    my $self = shift;
    my ($file, $dur) = @_;

    my $fh;
    unless (open($fh, '<', $file)) {
        warn "Could not open file $file for reading\n";
        return 0;
    }
    my @lines = <$fh>;
    close($fh);

    my $tagged = $self->retag_lines(\@lines, $dur);

    return $self->write_file_atomic($file, $tagged);
}

sub retag_lines {
    my $self = shift;
    my ($lines, $dur) = @_;

    my @out;
    my $injected;
    for my $line (@$lines) {
        # DUR(ATION)? (not DUR(ATION)) so we also match the 'HARNESS-DUR-*' alias
        # that Legacy.pm's directive parser accepts. Missing it left the stale
        # 'HARNESS-DUR-LONG' in place while a fresh 'HARNESS-DURATION-SHORT' was
        # appended -- two conflicting tags, with the stale one winning at parse.
        if ($line =~ m/^(\s*)#(\s*)HARNESS-(CAT(EGORY)?|DUR(ATION)?)-(LONG|MEDIUM|SHORT)$/i) {
            next if $injected++;
            $line = "${1}#${2}HARNESS-DURATION-" . uc($dur) . "\n";
        }
        push @out => $line;
    }

    unless ($injected) {
        my $new_line = "# HARNESS-DURATION-" . uc($dur) . "\n";
        my @header;
        while (@out && $out[0] =~ m/^(#|use\s|package\s)/) {
            push @header => shift @out;
        }

        unshift @out => (@header, $new_line);
    }

    return \@out;
}

sub write_file_atomic {
    my $self = shift;
    my ($file, $lines) = @_;

    my $tmp = "$file.tmp$$";

    my $fh;
    unless (open($fh, '>', $tmp)) {
        warn "Could not open temp file '$tmp' for writing: $!\n";
        return 0;
    }

    # stdio buffering can defer a write error (e.g. ENOSPC) to close(), so both
    # print AND close must be checked before we trust the tempfile.
    my $ok = print {$fh} @$lines;
    $ok &&= close($fh);

    unless ($ok) {
        warn "Could not write temp file '$tmp': $!\n";
        unlink($tmp);
        return 0;
    }

    unless (rename($tmp, $file)) {
        warn "Could not rename '$tmp' over '$file': $!\n";
        unlink($tmp);
        return 0;
    }

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::speedtag - Tag tests with duration (short medium long) using a source log

=head1 DESCRIPTION

This command will read the test durations from a log and tag/retag all tests
from the log based on the max durations for each type.


=head1 USAGE

    $ yath [YATH OPTIONS] speedtag [OPTIONS]

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

=head3 speedtag options

=over 4

=item --duration

=item --durations

=item --generate-durations-file

=item --duration=/path/to/durations.json

=item --durations=/path/to/durations.json

=item --generate-durations-file=/path/to/durations.json

=item --no-generate-durations-file

Write out a duration json file, if no path is provided 'duration.json' will be used. The .json extension is added automatically if omitted.


=item --pretty

=item --no-pretty

Generate a pretty 'durations.json' file when combined with --generate-durations-file. (sorted and multilines)


=back


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

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut


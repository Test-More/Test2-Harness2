package App::Yath2::Command::watch;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness2::Renderer::Base;
use Test2::Harness2::Util::UUID qw/gen_uuid/;

use App::Yath2::RenderLoop;
use App::Yath2::RenderLoop::LiveProducer;

use parent 'App::Yath2::Command::run';
use Test2::Harness2::Util::HashBase;

sub group { 'persist' }

sub summary  { "Monitor the persistent test runner" }
sub cli_args { "" }

sub pfile_params { (no_fatal => 1) }

sub description {
    return <<"    EOT";
This command will monitor a persistent instance of yath, rendering the runner's
(and its preload stages') output as it happens. STDOUT and STDERR are surfaced
from the runner's recorded events over runner.socket, so may not be in strict
order.
    EOT
}

# `yath watch` is a GLOBAL runner.socket subscriber. It connects to
# runner.socket (via the shared App::Yath2::Client, with NO run_id -- the global
# subscription that mirrors every run plus the global/runner-lifecycle bucket),
# and renders the runner's and each preload stage's recorded output through the
# reusable base renderer
# (Test2::Harness2::Renderer::Base::step_runner_output, which locates the runner
# events file by the workdir path and each stage's events file from the
# transition state). This is what surfaces the SIGHUP-reload line the runner
# prints: it is captured in runner-events.jsonl.zst and tailed here.
sub run {
    my $self = shift;

    my $args = $self->args;
    shift @$args if @$args && $args->[0] eq '--';
    my $stop = (@$args && $args->[0] eq 'STOP') ? 1 : 0;

    my $data = $self->pfile_data;    # prints the discovery banner, dies if none
    $self->client->attach_runner($data->{pid});

    # Global subscription: no run_id, so the runner forwards every run's frames
    # plus the global/runner-lifecycle frames. If the runner cannot be reached (it
    # died), the LiveProducer falls back to a standalone monitor so the base
    # renderer still tails the recorded runner events file by path.
    my $sub = $self->client->connect_subscriber;

    # A runner-output-only LiveProducer (the engine is a plain Renderer::Base, so
    # it tails runner/stage output and does no per-job ordering or run rollup). It
    # exits only on an idle tick once a stop condition holds: STOP means stop as
    # soon as nothing new is pending; otherwise watch until the runner goes away
    # (its persist file vanishes / its socket closes).
    my $producer;
    $producer = App::Yath2::RenderLoop::LiveProducer->new(
        engine     => $self->runner_renderer,
        subscriber => $sub,
        done_check => sub {
            return 0 unless $producer->idle;
            return 1 if $stop;
            return 1 if $sub && $sub->closed;
            return 1 unless -f $self->pfile->path;
            return 0;
        },
    );

    my $loop = App::Yath2::RenderLoop->new(
        renderers => $self->renderers,
        settings  => $self->settings,
        run_id    => $producer->engine->run_id,
        plugins   => $self->settings->harness->plugins,
        producer  => $producer,
    );

    $loop->start;
    $loop->finish;

    return 0;
}

# The runner-output render ENGINE: a base renderer that owns the
# events-file-by-path location + the runner/stage output tail. watch only drives
# step_runner_output through it (runner/global output, not per-job state). It runs
# in COLLECT mode (no sink renderers) -- the render loop owns the dispatch fan-out.
sub runner_renderer {
    my $self = shift;

    my $settings = $self->settings;

    my $show_runner_output = 1;
    $show_runner_output = $settings->display->hide_runner_output ? 0 : 1
        if $settings->check_group('display');

    # The watch session is a GLOBAL subscriber with no run scope; runner/stage
    # output is run-level, but the events it emits still need a run_id (the harness
    # Event requires one). Use a synthetic per-session id.
    return Test2::Harness2::Renderer::Base->new(
        settings           => $settings,
        renderers          => [],
        workdir            => $self->workdir,
        run_id             => gen_uuid(),
        show_runner_output => $show_runner_output,
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::watch - Monitor the persistent test runner

=head1 DESCRIPTION

This command monitors a persistent instance of yath by subscribing to its
C<runner.socket> as a global subscriber and rendering the runner's (and its
preload stages') recorded output as it happens. STDOUT and STDERR are surfaced
from the runner's recorded events, so may not be in strict order.


=head1 USAGE

    $ yath [YATH OPTIONS] watch [OPTIONS]

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


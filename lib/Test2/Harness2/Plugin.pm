package Test2::Harness2::Plugin;
use strict;
use warnings;

use Scalar::Util qw/blessed/;

our $VERSION = '2.000000';

# Plugin setup/teardown run in the RUNNER. A run_collected aux
# process pushes its pid here so the runner can stop it at teardown; the runner
# localizes this to its own list around
# Test2::Harness2::Runner's setup_plugins/teardown_plugins.
our $AUX_PIDS;

# Document, but do not implement
#sub changed_files {}
#sub changed_diff {}

sub munge_search {}

sub claim_file {}

sub munge_files {}

sub inject_run_data {}

sub setup {}

sub teardown {}

sub TO_JSON { ref($_[0]) || "$_[0]" }

# The common Test2::Collector args for a plugin "aux" collector. Its
# output is captured as collector EVENTS (a file recorder plus a socket reporter to
# runner.socket), so the runner folds it and the renderer shows it -- tagged with
# $name. Runs only inside the runner, where the
# runner workdir (T2_HARNESS_WORKDIR) and runner.socket exist.
sub _aux_collect_args {
    my $this = shift;
    my ($name) = @_;

    require File::Spec;
    require Test2::Collector::Recorder::Zstd;
    require Test2::Harness2::Util;
    require Test2::Harness2::Util::UUID;

    my $dir = $ENV{T2_HARNESS_WORKDIR}
        or die "Plugin aux collection requires a runner workdir; plugin setup/teardown now run in the runner.\n";

    my $efile  = File::Spec->catfile($dir, "aux-${name}-" . Test2::Harness2::Util::UUID::gen_uuid() . ".jsonl.zst");
    my $socket = File::Spec->catfile($dir, 'runner.socket');

    my $reporter = Test2::Harness2::Util::socket_reporter("collector:aux:$name", $socket);

    return (
        is_test            => 0,
        # "aux:NAME" lets Renderer::Base / RunnerReader tag this collector's output
        # with NAME -- the historical "(NAME)" aux output shape.
        name               => "aux:$name",
        record_transitions => 1,
        recorder           => Test2::Collector::Recorder::Zstd->new(file => $efile),
        ($reporter ? (reporter => $reporter) : ()),
    );
}

sub shellcall {
    my $this = shift;
    my ($settings, $name, @cmd) = @_;

    my @caller = caller();
    my $at = "at $caller[1] line $caller[2].\n";
    die "Invalid settings ($settings) $at" unless blessed($settings) && $settings->isa('Getopt::Yath::Settings');
    die "No name provided $at"    unless $name;
    die "No command provided $at" unless @cmd && length($cmd[0]);

    require Test2::Collector;
    require Test2::Harness2::Util;

    # Synchronous: collect runs the command to completion in a child, capturing its
    # output as events; we return the command's exit status. watch_parent_pid is the
    # runner pid ($$ here, in the runner) so the aux collector dies with the runner
    # (ARCHITECTURE.md §4.1).
    my $info = Test2::Collector::collect(
        $this->_aux_collect_args($name),
        watch_parent_pid => $$,
        exec             => [@cmd],
    );

    return Test2::Harness2::Util::collector_exit_code($info);
}

sub run_collected {
    my $this = shift;
    my ($settings, $name, @run) = @_;

    my @caller = caller();
    my $at = "at $caller[1] line $caller[2].\n";
    die "Invalid settings ($settings) $at" unless blessed($settings) && $settings->isa('Getopt::Yath::Settings');
    die "No name provided $at"          unless $name;
    die "No code or command provided $at" unless @run;

    require Test2::Collector;

    # Non-blocking: fork a collector that runs the coderef (or execs the command)
    # and keeps capturing its output for the rest of the run -- e.g. a service the
    # plugin starts in setup(). Returns the collector pid; the runner tracks it via
    # AUX_PIDS and stops it at teardown, and watch_parent_pid ($$ = runner) is the
    # fallback so it dies with the runner. Replaces the old fork + redirect_io.
    my %target = (ref($run[0]) eq 'CODE') ? (run => $run[0]) : (exec => [@run]);

    my $pid = Test2::Collector::spawn_collector(
        $this->_aux_collect_args($name),
        watch_parent_pid => $$,
        %target,
    );

    push @$AUX_PIDS => $pid if $AUX_PIDS;

    return $pid;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Plugin - Base class for Test2::Harness2 plugins.

=head1 DESCRIPTION

This class holds the methods specific to L<Test2::Harness2> which
is the backend. Most of the time you actually want to subclass
L<App::Yath2::Plugin> which subclasses this class, and holds additional methods
that apply to yath (the UI layer).

=head1 SYNOPSIS

You probably want to subclass L<App::Yath2::Plugin> instead. This class here
mainly exists to separate concerns, but is not something you should use
directly.

    package Test2::Harness2::Plugin::MyPlugin;

    use parent 'Test2::Harness2::Plugin';

    # ... Define methods

    1;

=head1 METHODS

=over 4

=item $plugin->munge_search($input, $default_search, $settings)

C<$input> is an arrayref of files and/or directories provided at the command
line.

C<$default_search> is an arrayref with the default files/directories pulled in
when nothing is specified at the command ine.

C<$settings> is an instance of L<Getopt::Yath::Settings>

=item $undef_or_inst = $plugin->claim_file($path, $settings)

This is a chance for a plugin to claim a test file early, before Test2::Harness2
takes care of it. If your plugin does not want to claim the file just return
undef. To claim the file return an instance of L<App::Yath2::TestFile>
created with C<$path>.

=item $plugin->munge_files(\@tests, $settings)

This is an opportunity for your plugin to modify the data for any test file
that will be run. The first argument is an arrayref of
L<App::Yath2::TestFile> objects.

This is also the hook for assigning preload stages at queue time: call
C<set_no_preload>, C<set_require_preload>, or C<set_preload_list> on a test to
set or clear its preload fields. The override is validated when the queue item
is built.

=item $hashref = $plugin->duration_data($settings, $test_names)

If defined, this can return a hashref of duration data. This should return
undef if no duration data is provided. The first plugin listed that provides
duration data wins, no other plugins will be checked once duration data is
obtained.

Example duration data:

    {
        't/foo.t' => 'medium',
        't/bar.t' => 'short',
        't/baz.t' => 'long',
    }

=item $hashref_or_arrayref = $plugin->coverage_data(\@changed)

=item $hashref_or_arrayref = $plugin->coverage_data()

If defined, this can return a hashref of all coverage data, or an arrayref of
tests that cover the tests listed in @changed. This should return undef if no
coverage data is available. The first plugin to provide coverage data wins, no
other plugins will be checked once coverage data has been obtained.

Examples:

    [
        'foo.t',
        'bar.t',
        'baz.t',
    ]

    {
        'lib/Foo.pm' => [
            't/foo.t',
            't/integration.t',
        ],
        'lib/Bar.pm' => [
            't/bar.t',
            't/integration.t',
        ],
    }

=item $plugin->post_process_coverage_tests($settings, \@tests)

This is an opportunity for a plugin to do post-processing on the list of
coverage tests to run. This is mainly useful to remove duplicates if multiple
plugins add coverage data, or merging entries where applicable. This will be
called after all plugins have generated their coverage test list.

Plugins may implement this without implementing coverage_data(), making this
useful if you want to use a pre-existing coverage module and want to do
post-processing on what it provides.

=item $plugin->inject_run_data(meta => $meta, fields => $fields, run => $run)

This is a callback that lets your plugin add meta-data or custom fields to the
run event. The meta-data and fields are available in the event log, and are
particularily useful to a UI layer consuming that log.

    sub inject_run_data {
        my $class  = shift;
        my %params = @_;

        my $meta   = $params{meta};
        my $fields = $params{fields};

        # Meta-data is a hash, each plugin should define its own key, and put
        # data under that key
        $meta->{MyPlugin}->{stuff} = "Stuff!";

        # Fields is an array of fields that a UI might want to display when showing the run.
        push @$fields => {name => 'MyPlugin', details => "Human Friendly Stuff", raw => "Less human friendly stuff", data => $all_the_stuff};

        return;
    }

=item $plugin->setup($settings)

This is a callback that lets you run setup logic when the runner starts. Note
that in a persistent runner this is run once on startup, it is not run for each
C<run> command against the persistent runner.

B<Runs in the runner>: C<setup>/C<teardown> are invoked by the runner
after its C<runner.socket> is bound, B<not> in the C<test>/C<start>/C<stop>
command process. This is what lets C<shellcall>/C<run_collected> report their
output as collector events over C<runner.socket>, and makes any process you start
a runner child that dies with the runner. (1.0 split this into C<client_*> +
C<instance_*> only to keep the 1.0 namespaces back-compatible; the C<*2>
namespaces have no such constraint, so the single C<setup>/C<teardown> live on the
runner -- see C<ARCHITECTURE.md>.)

=item $plugin->teardown($settings)

This is a callback that lets you run teardown logic when the runner stops. Note
that in a persistent runner this is run once on termination, it is not run for
each C<run> command against the persistent runner. Like C<setup>, this runs in the
runner (at shutdown), not the command.

=item @files = $plugin->changed_files($settings)

Get a list of files that have changed. Plugins are free to define what
"changed" means. This may be used by the finder to determine what tests to run
based on coverage data collected in previous runs.

Note that data from all changed_files() calls from all plugins will be merged.

=item ($type, $value) = $plugin->changed_diff($settings)

Generate a diff that can be used to calculate changed files/subs for which to
run tests. Unlike changed_files(), only 1 diff will be used, first plugin
listed that returns one wins. This is not run at all if a diff is provided via
--changed-diff.

Diffs must be in the same format as this git command:

    git diff -U1000000 -W --minimal BASE_BRANCH_OR_COMMIT

Some other diff formats may work by chance, but they are not dirfectly
supported. In the future other diff formats may be directly supported, but not
yet.

The following return sets are allowed:

=over 4

=item file => string

Path to a diff file

=item diff => string

In memory diff as a single string

=item lines => \@lines

Diff where each line is a seperate string in an arrayref.

=item line_sub => sub { ... }

Sub that returns one line per call and undef when there are no more lines

=item handle => $FH

A filehandle to the diff

=back

=item $exit = $plugin->shellcall($settings, $name, $cmd)

=item $exit = $plugin->shellcall($settings, $name, @cmd)

Run an external command B<synchronously> and return its exit status (like
C<system()>). The command's STDOUT/STDERR are captured by a yath collector
reporting to C<runner.socket>, so its output is seen as events and is part of the
yath log (tagged with C<$name>) -- no flat files. Must run in the runner
(C<setup>/C<teardown>); the aux collector watches the runner pid so it dies with
the runner.

$name is required because it is used as the output tag (best to limit it to 8
characters) and in the collector's events file name.

=item $pid = $plugin->run_collected($settings, $name, sub { ... })

=item $pid = $plugin->run_collected($settings, $name, @cmd)

Run a coderef (or exec a command) B<non-blocking> in a collector child whose
output keeps being captured for the rest of the run -- e.g. a service a plugin
starts in C<setup()> that continues to produce output after C<setup> returns.
Returns the collector pid. The runner tracks it and stops it at C<teardown>, and
the collector watches the runner pid so it (and its child) die with the runner.
This replaces the old C<fork> + C<redirect_io> pattern; there is no detach /
C<setsid> -- nothing started by the runner survives the runner.

$name is required (output tag + events file name; best to limit it to 8
characters).

=item $plugin->TO_JSON

This is here as a bare minimum serialization method. It returns the plugin
class name.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

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

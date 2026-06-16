package App::Yath2::RunPlan;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness2::Run();
use Test2::Harness2::Util::Queue();
use Test2::Harness2::Util qw/mod2file chmod_tmp/;

use Test2::Harness2::Util::HashBase qw{
    <settings
    <workdir
    <finder_args
    +run
    +tasks_queue
    <tasks
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::RunPlan - Run and task-queue construction for the test/run commands.

=head1 DESCRIPTION

Both the transient C<yath test> command and the persistent C<yath run> command
have to turn a settings object into a concrete run: build the
L<Test2::Harness2::Run> (and its run directory), find and sort the test files,
and assemble the per-file task list. This object owns that plumbing so the
commands only have to delegate to it.

It is a plain L<Object::HashBase> built from a settings object plus the workdir;
it touches no socket and spawns no runner, so it can be constructed and exercised
standalone in a unit test. The run object is built lazily (L</run>) -- creating
its run directory as a side effect, exactly as the inline command code did -- and
L</populate> finds the files, applies any plugin sort, builds the tasks, and
optionally writes the per-run C<queue.jsonl> the gatherer reads.

=head1 SYNOPSIS

    use App::Yath2::RunPlan;

    my $plan = App::Yath2::RunPlan->new(
        settings    => $settings,
        workdir     => $workdir,
        finder_args => [multi_project => 1],    # optional
    );

    my $run    = $plan->run;       # build the run + its run dir
    my $run_id = $run->run_id;
    my $queue  = $plan->tasks_queue;

    # Find + sort the files, build the tasks, return the job count. Pass
    # write_queue => 1 to also append the tasks to the per-run queue.jsonl.
    my $job_count = $plan->populate(write_queue => 1);
    my $tasks     = $plan->tasks;

=head1 PUBLIC METHODS

=over 4

=item $settings = $plan->settings

The settings object the plan was built from.

=item $dir = $plan->workdir

The working directory the run lives under.

=item $args = $plan->finder_args

The extra arguments (an arrayref or list) passed to the finder constructor, as
provided to the constructor (defaults to an empty list).

=item run

=item $run = $plan->run

The L<Test2::Harness2::Run> for this plan. Built (and cached) on first use from
C<< $settings->run->all >>; building it creates the run directory under the
workdir and C<chmod_tmp>s the workdir, matching the old inline C<build_run>.

=item $id = $plan->run_id

Convenience accessor for C<< $plan->run->run_id >>.

=item tasks_queue

=item $queue = $plan->tasks_queue

The per-run C<queue.jsonl> L<Test2::Harness2::Util::Queue> (under the run
directory). Built (and cached) on first use.

=item populate

=item $job_count = $plan->populate(%params)

Find the test files, apply any plugin sort, build a task per file, and stash the
task list (see L</tasks>). Returns the number of tasks (job count). With
C<< write_queue => 1 >> each task is also appended to L</tasks_queue> as it is
built (the gatherer-fed C<queue.jsonl>); without it the queue file is left
untouched.

=item tasks

=item $tasks = $plan->tasks

The task list produced by the most recent L</populate> (an arrayref; C<undef>
before the first call).

=back

=cut

sub run ($self) {
    return $self->{+RUN} if $self->{+RUN};

    my $settings = $self->{+SETTINGS};
    my $dir      = $self->{+WORKDIR};

    my $run = Test2::Harness2::Run->new($settings->run->all);

    mkdir($run->run_dir($dir)) or die "Could not make run dir: $!";
    chmod_tmp($dir);

    return $self->{+RUN} = $run;
}

sub run_id ($self) { return $self->run->run_id }

sub tasks_queue ($self) {
    return $self->{+TASKS_QUEUE} //= Test2::Harness2::Util::Queue->new(
        file => File::Spec->catfile($self->run->run_dir($self->{+WORKDIR}), 'queue.jsonl'),
    );
}

sub populate ($self, %params) {
    my $write_queue = $params{write_queue} ? 1 : 0;

    my $run          = $self->run;
    my $settings     = $self->{+SETTINGS};
    my $finder_class = $settings->finder->finder;
    require(mod2file($finder_class));
    my $finder = $finder_class->new($settings->finder->all, @{$self->_finder_args});

    my $tasks_queue = $self->tasks_queue;
    my $plugins     = $settings->harness->plugins;

    my @files = @{$finder->find_files($plugins, $settings)};

    for my $plugin (@$plugins) {
        if ($plugin->can('sort_files_2')) {
            @files = $plugin->sort_files_2(settings => $settings, files => \@files);
        }
        elsif ($plugin->can('sort_files')) {
            @files = $plugin->sort_files(@files);
        }
    }

    my @tasks;
    my $job_count = 0;
    for my $file (@files) {
        my $task = $file->queue_item(
            ++$job_count, $run->run_id,
            $settings->check_group('display') ? (verbose => $settings->display->verbose) : (),
        );

        $task->{category} = 'isolation' if $settings->debug->interactive;

        push @tasks => $task;

        # queue.jsonl is consumed ONLY by the yath-side gatherer (it walks the
        # workdir for events and learns the pending jobs from this file). The
        # runner pulls tasks from the socket-fed state, not this file, so the
        # transient path leaves it unwritten; the gated persistent path still
        # spawns the gatherer and asks for it.
        $tasks_queue->enqueue($task) if $write_queue;
    }

    $self->{+TASKS} = \@tasks;

    return $job_count;
}

=head1 PRIVATE METHODS

=over 4

=item $arrayref = $plan->_finder_args

The extra finder arguments normalized to an arrayref (an empty arrayref when none
were given), for use as a flat list in the finder constructor.

=back

=cut

sub _finder_args ($self) {
    my $args = $self->{+FINDER_ARGS} // [];
    return ref($args) eq 'ARRAY' ? $args : [$args];
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

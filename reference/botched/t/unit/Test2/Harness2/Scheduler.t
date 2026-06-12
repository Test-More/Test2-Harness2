use strict;
use warnings;
use Test2::V0;

use Test2::Harness2::Scheduler;
use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Workspace;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

{

    package FakeTestFile;
    sub new  { bless {file => $_[1]}, $_[0] }
    sub file { $_[0]->{file} }
}

sub fake_tf {
    my ($name) = @_;
    return FakeTestFile->new($name);
}

sub make_run {
    my (@files) = @_;
    return Test2::Harness2::Run->new(
        test_files => [map { fake_tf($_) } @files],
    );
}

# A resource that always says "broken"
{

    package BrokenResource;
    use parent 'Test2::Harness2::Resource';

    sub applicable { 1 }
    sub available  { -1 }
}

# A resource that always says "unavailable" (temporarily)
{

    package BusyResource;
    use parent 'Test2::Harness2::Resource';

    sub applicable { 1 }
    sub available  { 0 }
}

# A resource that is only applicable to jobs whose test_file->{file} matches a pattern
{

    package SelectiveResource;
    use parent 'Test2::Harness2::Resource';

    sub applicable {
        my ($self, $job) = @_;
        return $job->test_file->{file} =~ /selective/;
    }
    sub available { -1 }
}

# A tracking plugin that records hook calls
{

    package TrackingPlugin;
    use parent 'Test2::Harness2::Plugin';

    sub init {
        my $self = shift;
        $self->{events} = [];
    }

    sub on_run_queued   { push @{$_[0]->{events}}, ['on_run_queued',   $_[1]] }
    sub on_job_queued   { push @{$_[0]->{events}}, ['on_job_queued',   $_[1]] }
    sub on_job_complete { push @{$_[0]->{events}}, ['on_job_complete', $_[1]] }
    sub on_run_complete { push @{$_[0]->{events}}, ['on_run_complete', $_[1]] }

    sub events { $_[0]->{events} }
}

# ---------------------------------------------------------------------------
# Construction and defaults
# ---------------------------------------------------------------------------
subtest 'construction and defaults' => sub {
    my $sched = Test2::Harness2::Scheduler->new();

    is($sched->runs,      [], "runs defaults to empty arrayref");
    is($sched->resources, [], "resources defaults to empty arrayref");
    is($sched->plugins,   [], "plugins defaults to empty arrayref");
    ok(!defined $sched->workspace, "workspace defaults to undef");
};

# ---------------------------------------------------------------------------
# queue_run adds run and indexes jobs
# ---------------------------------------------------------------------------
subtest 'queue_run indexes jobs' => sub {
    my $sched = Test2::Harness2::Scheduler->new();
    my $run   = make_run('t/a.t', 't/b.t');

    $sched->queue_run($run);

    is(scalar @{$sched->runs}, 1, "one run queued");

    my @jobs = @{$run->jobs};
    for my $job (@jobs) {
        my $found = $sched->find_job($job->uuid);
        is($found, $job, "job indexed by uuid");
    }
};

# ---------------------------------------------------------------------------
# next_job returns pending job when resources available
# ---------------------------------------------------------------------------
subtest 'next_job with available resources' => sub {
    my $resource = Test2::Harness2::Resource::JobCount->new(job_count => 2);
    my $sched    = Test2::Harness2::Scheduler->new(resources => [$resource]);
    my $run      = make_run('t/a.t', 't/b.t');

    $sched->queue_run($run);

    my $job1 = $sched->next_job();
    ok(defined $job1, "got a job");
    is($job1->status, 'running', "job status set to running");

    my $job2 = $sched->next_job();
    ok(defined $job2, "got a second job");
    isnt($job1->uuid, $job2->uuid, "different jobs");
};

# ---------------------------------------------------------------------------
# next_job returns undef when resources at capacity
# ---------------------------------------------------------------------------
subtest 'next_job returns undef at capacity' => sub {
    my $resource = Test2::Harness2::Resource::JobCount->new(job_count => 1);
    my $sched    = Test2::Harness2::Scheduler->new(resources => [$resource]);
    my $run      = make_run('t/a.t', 't/b.t');

    $sched->queue_run($run);

    my $job1 = $sched->next_job();
    ok(defined $job1, "first job dispatched");

    my $job2 = $sched->next_job();
    ok(!defined $job2, "second job not dispatched (at capacity)");
};

# ---------------------------------------------------------------------------
# next_job with BusyResource returns undef
# ---------------------------------------------------------------------------
subtest 'next_job returns undef with busy resource' => sub {
    my $resource = BusyResource->new();
    my $sched    = Test2::Harness2::Scheduler->new(resources => [$resource]);
    my $run      = make_run('t/a.t');

    $sched->queue_run($run);

    my $job = $sched->next_job();
    ok(!defined $job, "no job dispatched when resource busy");
};

# ---------------------------------------------------------------------------
# Broken resource (-1) causes job to be marked failed
# ---------------------------------------------------------------------------
subtest 'broken resource marks job failed' => sub {
    my $resource = BrokenResource->new();
    my $sched    = Test2::Harness2::Scheduler->new(resources => [$resource]);
    my $run      = make_run('t/a.t', 't/b.t');

    $sched->queue_run($run);

    # next_job should skip broken jobs and return undef (all jobs broken)
    my $job = $sched->next_job();
    ok(!defined $job, "no dispatchable job returned");

    # But the first job should be marked complete/failed
    my @jobs = @{$run->jobs};
    is($jobs[0]->status, 'complete', "broken job marked complete");
    ok(!$jobs[0]->passed, "broken job marked as not passed");
};

# ---------------------------------------------------------------------------
# Selective resource: non-applicable resource doesn't block
# ---------------------------------------------------------------------------
subtest 'non-applicable resource does not block' => sub {
    my $selective = SelectiveResource->new();
    my $sched     = Test2::Harness2::Scheduler->new(resources => [$selective]);
    my $run       = make_run('t/normal.t');

    $sched->queue_run($run);

    my $job = $sched->next_job();
    ok(defined $job, "job dispatched when resource not applicable");
    is($job->status, 'running', "job is running");
};

# ---------------------------------------------------------------------------
# job_complete releases resources and marks complete
# ---------------------------------------------------------------------------
subtest 'job_complete releases resources' => sub {
    my $resource = Test2::Harness2::Resource::JobCount->new(job_count => 1);
    my $sched    = Test2::Harness2::Scheduler->new(resources => [$resource]);
    my $run      = make_run('t/a.t', 't/b.t');

    $sched->queue_run($run);

    my $job1 = $sched->next_job();
    ok(defined $job1, "first job dispatched");

    # At capacity, can't get second
    ok(!defined $sched->next_job(), "at capacity");

    # Complete the first job
    $sched->job_complete($job1, passed => 1, exit_code => 0);

    is($job1->status,    'complete', "job status is complete");
    is($job1->passed,    1,          "job passed");
    is($job1->exit_code, 0,          "exit code set");

    # Now second should be available
    my $job2 = $sched->next_job();
    ok(defined $job2, "second job dispatched after release");
};

# ---------------------------------------------------------------------------
# job_complete triggers run completion
# ---------------------------------------------------------------------------
subtest 'job_complete triggers run completion hooks' => sub {
    my $plugin = TrackingPlugin->new();
    my $sched  = Test2::Harness2::Scheduler->new(plugins => [$plugin]);
    my $run    = make_run('t/only.t');

    $sched->queue_run($run);

    my $job = $sched->next_job();
    $sched->job_complete($job, passed => 1, exit_code => 0);

    ok($run->is_complete, "run is complete");

    my @events = @{$plugin->events};
    my @types  = map { $_->[0] } @events;

    is(
        \@types, [
            'on_run_queued',
            'on_job_queued',
            'on_job_complete',
            'on_run_complete',
        ],
        "plugin hooks fired in correct order"
    );
};

# ---------------------------------------------------------------------------
# all_complete
# ---------------------------------------------------------------------------
subtest 'all_complete' => sub {
    my $sched = Test2::Harness2::Scheduler->new();

    ok(!$sched->all_complete, "not complete with no runs");

    my $run = make_run('t/a.t');
    $sched->queue_run($run);

    ok(!$sched->all_complete, "not complete with pending jobs");

    my $job = $sched->next_job();
    $sched->job_complete($job, passed => 1, exit_code => 0);

    ok($sched->all_complete, "all complete after all jobs done");
};

# ---------------------------------------------------------------------------
# job_params returns correct structure (with Workspace)
# ---------------------------------------------------------------------------
subtest 'job_params returns correct structure' => sub {
    my $ws       = Test2::Harness2::Workspace->new(cleanup => 1);
    my $settings = bless {timeout => 60}, 'FakeSettings';
    my $run      = Test2::Harness2::Run->new(
        test_files    => [fake_tf('t/params.t')],
        test_settings => $settings,
    );

    my $sched = Test2::Harness2::Scheduler->new(workspace => $ws);
    $sched->queue_run($run);

    my $job    = $run->jobs->[0];
    my $params = $sched->job_params($job->uuid);

    is($params->{test_file}, 't/params.t', "test_file path");
    is($params->{uuid},      $job->uuid,   "uuid matches");
    is($params->{run_id},    $run->uuid,   "run_id matches");
    ok(defined $params->{log_dir}, "log_dir set with workspace");
    is($params->{test_settings}, $settings, "test_settings from run");

    # Cleanup workspace
    $ws->cleanup();
};

# ---------------------------------------------------------------------------
# job_params without workspace
# ---------------------------------------------------------------------------
subtest 'job_params without workspace' => sub {
    my $run   = make_run('t/nows.t');
    my $sched = Test2::Harness2::Scheduler->new();
    $sched->queue_run($run);

    my $job    = $run->jobs->[0];
    my $params = $sched->job_params($job->uuid);

    ok(!defined $params->{log_dir},       "log_dir undef without workspace");
    ok(!defined $params->{test_settings}, "test_settings undef when not set");
};

# ---------------------------------------------------------------------------
# queue_rerun creates new uuid
# ---------------------------------------------------------------------------
subtest 'queue_rerun creates new uuid' => sub {
    my $sched = Test2::Harness2::Scheduler->new();
    my $run   = make_run('t/retry.t');

    $sched->queue_run($run);

    my $job      = $run->jobs->[0];
    my $old_uuid = $job->uuid;

    ok(defined $sched->find_job($old_uuid), "old uuid indexed");

    $sched->queue_rerun($old_uuid);

    my $new_uuid = $job->uuid;
    isnt($new_uuid, $old_uuid, "uuid changed after rerun");

    ok(!defined $sched->find_job($old_uuid), "old uuid no longer indexed");
    ok(defined $sched->find_job($new_uuid),  "new uuid indexed");

    is($job->status,  'pending', "job status reset to pending");
    is($job->try_num, 1,         "try_num incremented");
};

# ---------------------------------------------------------------------------
# add_tests_to_run
# ---------------------------------------------------------------------------
subtest 'add_tests_to_run' => sub {
    my $sched = Test2::Harness2::Scheduler->new();
    my $run   = make_run('t/first.t');

    $sched->queue_run($run);
    is(scalar @{$run->jobs}, 1, "one job initially");

    $sched->add_tests_to_run($run->uuid, [fake_tf('t/second.t')]);

    is(scalar @{$run->jobs}, 2, "two jobs after add");

    my $new_job = $run->jobs->[1];
    ok(defined $sched->find_job($new_job->uuid), "new job indexed");
};

# ---------------------------------------------------------------------------
# find_run
# ---------------------------------------------------------------------------
subtest 'find_run' => sub {
    my $sched = Test2::Harness2::Scheduler->new();
    my $run   = make_run('t/find.t');

    $sched->queue_run($run);

    my $found = $sched->find_run($run->uuid);
    is($found, $run, "found run by uuid");

    ok(!defined $sched->find_run('nonexistent'), "undef for unknown uuid");
};

# ---------------------------------------------------------------------------
# Multiple runs: oldest first ordering
# ---------------------------------------------------------------------------
subtest 'multiple runs oldest first' => sub {
    my $sched = Test2::Harness2::Scheduler->new();
    my $run1  = make_run('t/r1.t');
    my $run2  = make_run('t/r2.t');

    $sched->queue_run($run1);
    $sched->queue_run($run2);

    my $job = $sched->next_job();
    is($job->run_id, $run1->uuid, "job from first (oldest) run dispatched first");
};

# ---------------------------------------------------------------------------
# Plugin hooks fire at correct times
# ---------------------------------------------------------------------------
subtest 'plugin hooks fire correctly' => sub {
    my $plugin = TrackingPlugin->new();
    my $sched  = Test2::Harness2::Scheduler->new(plugins => [$plugin]);
    my $run    = make_run('t/hooks.t');

    # on_run_queued
    $sched->queue_run($run);
    is(scalar @{$plugin->events}, 1,               "one event after queue_run");
    is($plugin->events->[0][0],   'on_run_queued', "on_run_queued fired");

    # on_job_queued
    my $job = $sched->next_job();
    is(scalar @{$plugin->events}, 2,               "two events after next_job");
    is($plugin->events->[1][0],   'on_job_queued', "on_job_queued fired");

    # on_job_complete + on_run_complete (single-job run)
    $sched->job_complete($job, passed => 1, exit_code => 0);
    is(scalar @{$plugin->events}, 4,                 "four events after job_complete");
    is($plugin->events->[2][0],   'on_job_complete', "on_job_complete fired");
    is($plugin->events->[3][0],   'on_run_complete', "on_run_complete fired");
};

# ---------------------------------------------------------------------------
# job_complete with log_file
# ---------------------------------------------------------------------------
subtest 'job_complete sets log_file' => sub {
    my $sched = Test2::Harness2::Scheduler->new();
    my $run   = make_run('t/loggy.t');

    $sched->queue_run($run);
    my $job = $sched->next_job();

    $sched->job_complete($job, passed => 1, exit_code => 0, log_file => '/tmp/test.jsonl');

    is($job->log_file, '/tmp/test.jsonl', "log_file set on job");
};

done_testing;

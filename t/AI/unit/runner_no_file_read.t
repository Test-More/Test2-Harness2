use Test2::V0;
# HARNESS-DURATION-SHORT

# Chunk 14: reading/scanning test files is a command-side (App::Yath2) concern.
# The runner plans and dispatches a run purely from the already-computed task
# payload, never re-reading the test file. This test proves that at the runner
# boundary:
#   1. The producing-side state object (Test2::Harness2::TestFile) and the runner
#      Job both work for a file that does not exist on disk.
#   2. Loading the runner-side classes does NOT pull in the command-side reader
#      (App::Yath2::TestFile) or finder (App::Yath2::Finder).

use File::Spec;

use Test2::Harness2::TestFile;
use Test2::Harness2::Runner::Job;

# A task payload exactly like App::Yath2::TestFile->queue_item produces, but for
# a file that is guaranteed not to exist. If anything tried to open/scan it, the
# scan would fail or the path checks would change behavior.
my $bogus = '/no/such/dir/definitely-not-here-12345.t';
ok(!-e $bogus, "the test file does not exist on disk");

my $task = {
    file        => $bogus,
    rel_file    => 'definitely-not-here-12345.t',
    job_id      => 'JOB-NO-READ',
    job_name    => '1',
    run_id      => 'RUN-NO-READ',
    stage       => 'default',
    category    => 'general',
    duration    => 'medium',
    rank        => 50,
    use_fork    => 1,
    use_preload => 1,
    use_timeout => 1,
    smoke       => 0,
    io_events   => 1,
    binary      => 0,
    non_perl    => 0,
};

subtest state_object_is_file_free => sub {
    my $tf = Test2::Harness2::TestFile->from_task($task);
    is($tf->file,     $bogus,     "file accessor works without the file existing");
    is($tf->stage,    'default',  "stage comes from the payload, not a scan");
    is($tf->category, 'general',  "category comes from the payload, not a scan");
    ok(!-e $bogus, "still did not create or require the file");
};

subtest runner_job_builds_without_reading_the_file => sub {
    # Minimal truthy stubs: Job->init only requires runner/run/settings to be
    # present, and the accessors below never touch them or the file contents.
    my $job = Test2::Harness2::Runner::Job->new(
        task     => $task,
        runner   => 1,
        run      => 1,
        settings => 1,
    );

    is($job->job_id, 'JOB-NO-READ', "job_id read from the payload");
    is($job->file, $bogus, "file path taken from the payload");
    is($job->rel_file, File::Spec->abs2rel($bogus), "rel_file derived from the path without opening the file");
    ok(!-e $bogus, "building the job did not read or create the file");
};

subtest runner_side_does_not_load_the_reader => sub {
    # Producing-results code (Test2::Harness2) must not pull in the UI-side reader
    # or finder. They were never required by the modules loaded above.
    ok(!$INC{'App/Yath2/TestFile.pm'}, "App::Yath2::TestFile not loaded by the runner side");
    ok(!$INC{'App/Yath2/Finder.pm'},   "App::Yath2::Finder not loaded by the runner side");
};

done_testing;

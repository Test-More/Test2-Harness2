use Test2::V0 -target => 'Test2::Harness2::TestFile';
# HARNESS-DURATION-SHORT

use ok $CLASS;

# The state-only object must NEVER read the test file. Point it at a file that
# does not exist on disk: construction and every accessor must work anyway,
# proving it is a pure view over the already-computed task payload.
my $task = {
    file        => '/this/file/does/not/exist/at/all.t',
    rel_file    => 'at/all.t',
    job_id      => 'JOB-1',
    job_name    => '42',
    run_id      => 'RUN-1',
    stage       => 'default',
    category    => 'general',
    duration    => 'medium',
    rank        => 50,
    conflicts   => ['passwd'],
    switches    => ['-w'],
    test_args   => ['--foo'],
    env_vars    => {FOO => 1},
    input       => "stdin\n",
    min_slots   => 1,
    max_slots   => 2,
    use_fork    => 1,
    use_preload => 0,
    use_timeout => 1,
    smoke       => 0,
    io_events   => 1,
    binary      => 0,
    non_perl    => 0,
    retry       => 2,
    retry_isolated => 1,
    event_timeout     => 90,
    post_exit_timeout => 85,
    job_class   => 'My::Job',
    stamp       => 123.45,
};

ok(!-e $task->{file}, "the test file genuinely does not exist on disk");

my $tf = $CLASS->from_task($task);
isa_ok($tf, [$CLASS], "built a state object from a task payload");

subtest accessors => sub {
    is($tf->file,        $task->{file},        "file");
    is($tf->rel_file,    'at/all.t',           "rel_file");
    is($tf->job_id,      'JOB-1',              "job_id");
    is($tf->job_name,    '42',                 "job_name");
    is($tf->run_id,      'RUN-1',              "run_id");
    is($tf->stage,       'default',            "stage");
    is($tf->category,    'general',            "category");
    is($tf->duration,    'medium',             "duration");
    is($tf->rank,        50,                   "rank");
    is($tf->conflicts,   ['passwd'],           "conflicts");
    is($tf->switches,    ['-w'],               "switches");
    is($tf->test_args,   ['--foo'],            "test_args");
    is($tf->env_vars,    {FOO => 1},           "env_vars");
    is($tf->input,       "stdin\n",            "input");
    is($tf->min_slots,   1,                    "min_slots");
    is($tf->max_slots,   2,                    "max_slots");
    is($tf->use_fork,    1,                    "use_fork");
    is($tf->use_preload, 0,                    "use_preload");
    is($tf->use_timeout, 1,                    "use_timeout");
    is($tf->smoke,       0,                    "smoke");
    is($tf->io_events,   1,                    "io_events");
    is($tf->binary,      0,                    "binary");
    is($tf->non_perl,    0,                    "non_perl");
    is($tf->retry,       2,                    "retry");
    is($tf->retry_isolated,    1,              "retry_isolated");
    is($tf->event_timeout,     90,             "event_timeout");
    is($tf->post_exit_timeout, 85,             "post_exit_timeout");
    is($tf->job_class,   'My::Job',            "job_class");
    is($tf->stamp,       123.45,               "stamp");
};

subtest field_and_serialization => sub {
    is($tf->field('job_id'), 'JOB-1', "field() reads an arbitrary payload key");
    is($tf->field('nope'), undef, "field() returns undef for an unknown key");

    is($tf->task_data, $task, "task_data round-trips the payload");
    is($tf->TO_JSON,   $task, "TO_JSON serializes back to the payload");

    # from_task shallow-copies: mutating the object's data does not touch the
    # original input hash.
    ref_is_not($tf->task_data, $task, "task_data is a copy, not the same ref");
};

subtest validation => sub {
    like(
        dies { $CLASS->new() },
        qr/'task_data' is a required attribute/,
        "new() without task_data dies",
    );

    like(
        dies { $CLASS->from_task() },
        qr/from_task requires a task hashref/,
        "from_task() without a hashref dies",
    );

    like(
        dies { $CLASS->from_task({job_id => 'x'}) },
        qr/missing a 'file'/,
        "from_task() without a file dies",
    );
};

done_testing;

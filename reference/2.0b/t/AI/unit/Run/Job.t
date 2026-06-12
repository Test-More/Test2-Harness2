use Test2::V0;
use v5.38;

use lib 't2clib';    # temporary until Test2-Collector is installed

use Test2::Harness2::Run::Job;

# A job is the complete, final spec for one test process: no sniffing, no
# discovery -- just the values a collector needs to run the test.

subtest defaults => sub {
    my $job = Test2::Harness2::Run::Job->new(test_file => 't/foo.t');

    ok($job->job_uuid,           "a job_uuid was generated");
    is($job->try,      1,        "try defaults to 1");
    is($job->env_vars, {},       "env_vars defaults to an empty hash");
    is($job->includes, [],       "includes defaults to an empty array");
    is($job->via,    'fork_exec', "via defaults to fork_exec");
    is($job->test_file, 't/foo.t', "test_file kept");
};

subtest required_and_validation => sub {
    like(
        dies { Test2::Harness2::Run::Job->new() },
        qr/'test_file' is a required attribute/,
        "test_file is required",
    );

    like(
        dies { Test2::Harness2::Run::Job->new(test_file => 't/a.t', via => 'spaceship') },
        qr/'spaceship' is not a supported 'via'/,
        "unknown via is rejected",
    );

    like(
        dies { Test2::Harness2::Run::Job->new(test_file => 't/a.t', env_vars => []) },
        qr/'env_vars' must be a hashref/,
        "env_vars must be a hashref",
    );

    like(
        dies { Test2::Harness2::Run::Job->new(test_file => 't/a.t', includes => {}) },
        qr/'includes' must be an arrayref/,
        "includes must be an arrayref",
    );
};

subtest round_trip => sub {
    my $job = Test2::Harness2::Run::Job->new(
        test_file => 't/foo.t',
        env_vars  => {FOO => 1, BAR => 'two'},
        includes  => ['lib', 't2clib'],
    );

    my $data = $job->TO_JSON;
    is(ref($data), 'HASH', "TO_JSON returns a plain hash");

    my $copy = Test2::Harness2::Run::Job->new(%$data);
    is($copy->job_uuid,  $job->job_uuid,  "job_uuid round-trips");
    is($copy->try,       $job->try,       "try round-trips");
    is($copy->test_file, $job->test_file, "test_file round-trips");
    is($copy->env_vars,  $job->env_vars,  "env_vars round-trips");
    is($copy->includes,  $job->includes,  "includes round-trips");
    is($copy->via,       $job->via,       "via round-trips");
};

done_testing;

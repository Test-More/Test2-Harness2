use Test2::V0;
use v5.38;

use lib 't2clib';    # temporary until Test2-Collector is installed

use Test2::Collector::Util::JSON qw/encode_json decode_json/;

use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;

# A run is a uuid plus one or more jobs, in complete final form. Hashref
# job entries are re-blessed into Run::Job, so a run rehydrated from its
# serialized form carries the same object graph.

subtest requires_jobs => sub {
    like(
        dies { Test2::Harness2::Run->new() },
        qr/'jobs' is a required attribute/,
        "jobs is required",
    );

    like(
        dies { Test2::Harness2::Run->new(jobs => []) },
        qr/'jobs' is a required attribute/,
        "an empty jobs list is rejected",
    );

    like(
        dies { Test2::Harness2::Run->new(jobs => [bless({}, 'Some::Other')]) },
        qr/'jobs' entries must be Test2::Harness2::Run::Job instances or hashrefs/,
        "a foreign blessed entry is rejected",
    );
};

subtest coercion => sub {
    my $run = Test2::Harness2::Run->new(
        jobs => [
            {test_file => 't/a.t'},
            Test2::Harness2::Run::Job->new(test_file => 't/b.t'),
        ],
    );

    ok($run->run_uuid, "a run_uuid was generated");
    is(scalar(@{$run->jobs}), 2, "both jobs present");
    isa_ok($_, ['Test2::Harness2::Run::Job'], "entry is a Run::Job") for @{$run->jobs};
    is($run->jobs->[0]->test_file, 't/a.t', "hashref entry coerced with its values");
};

subtest serialization_round_trip => sub {
    my $run = Test2::Harness2::Run->new(
        jobs => [{test_file => 't/a.t', env_vars => {X => 1}, includes => ['lib']}],
    );

    # The wire format: JSON via TO_JSON, decoded and fed back to new().
    my $copy = Test2::Harness2::Run->new(%{decode_json(encode_json($run))});

    is($copy->run_uuid, $run->run_uuid, "run_uuid round-trips");
    isa_ok($copy->jobs->[0], ['Test2::Harness2::Run::Job'], "job rehydrated as a Run::Job");
    is($copy->jobs->[0]->job_uuid, $run->jobs->[0]->job_uuid, "job_uuid round-trips");
    is($copy->jobs->[0]->env_vars, {X => 1}, "env_vars round-trips");
};

done_testing;

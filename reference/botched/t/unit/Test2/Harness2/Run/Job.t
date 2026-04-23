use strict;
use warnings;
use Test2::V0;

use Test2::Harness2::Run::Job;

# ---- Construction defaults ----
subtest 'construction defaults' => sub {
    my $job = Test2::Harness2::Run::Job->new(
        run_id => 'run-abc-123',
    );

    ok(defined $job->uuid, "uuid is auto-generated");
    like($job->uuid, qr/\S+/, "uuid is non-empty string");
    is($job->run_id,         'run-abc-123', "run_id stored correctly");
    is($job->status,         'pending',     "status defaults to 'pending'");
    is($job->try_num,        0,             "try_num defaults to 0");
    is($job->previous_uuids, [],            "previous_uuids starts empty");

    is($job->passed,    undef, "passed starts undef");
    is($job->exit_code, undef, "exit_code starts undef");
    is($job->log_file,  undef, "log_file starts undef");
};

# ---- UUID uniqueness ----
subtest 'uuid uniqueness' => sub {
    my $job1 = Test2::Harness2::Run::Job->new(run_id => 'r1');
    my $job2 = Test2::Harness2::Run::Job->new(run_id => 'r2');

    isnt($job1->uuid, $job2->uuid, "two distinct jobs get distinct UUIDs");
};

# ---- set_status transitions ----
subtest 'set_status transitions' => sub {
    my $job = Test2::Harness2::Run::Job->new(run_id => 'run-1');

    is($job->status, 'pending', "initial status is pending");

    $job->set_status('running');
    is($job->status, 'running', "status updated to running");

    $job->set_status('complete');
    is($job->status, 'complete', "status updated to complete");
};

# ---- set_result ----
subtest 'set_result stores passed and exit_code' => sub {
    my $job = Test2::Harness2::Run::Job->new(run_id => 'run-1');

    $job->set_result(passed => 1, exit_code => 0);
    is($job->passed,    1, "passed stored as true");
    is($job->exit_code, 0, "exit_code stored as 0");

    $job->set_result(passed => 0, exit_code => 1);
    is($job->passed,    0, "passed updated to false");
    is($job->exit_code, 1, "exit_code updated to 1");
};

# ---- set_log_file ----
subtest 'set_log_file stores path' => sub {
    my $job = Test2::Harness2::Run::Job->new(run_id => 'run-1');

    is($job->log_file, undef, "log_file starts undef");

    $job->set_log_file('/tmp/some/test.jsonl');
    is($job->log_file, '/tmp/some/test.jsonl', "log_file stored correctly");
};

# ---- retry creates new uuid and increments try_num ----
subtest 'retry resets state and tracks previous uuid' => sub {
    my $job = Test2::Harness2::Run::Job->new(run_id => 'run-1');

    # Set some state before retry
    my $orig_uuid = $job->uuid;
    $job->set_status('complete');
    $job->set_result(passed => 0, exit_code => 42);
    $job->set_log_file('/tmp/attempt0.jsonl');

    $job->retry();

    # UUID changed
    isnt($job->uuid, $orig_uuid, "uuid changed after retry");

    # try_num incremented
    is($job->try_num, 1, "try_num incremented to 1");

    # status reset to pending
    is($job->status, 'pending', "status reset to pending after retry");

    # result cleared
    is($job->passed,    undef, "passed cleared after retry");
    is($job->exit_code, undef, "exit_code cleared after retry");
    is($job->log_file,  undef, "log_file cleared after retry");

    # previous UUID tracked
    is($job->previous_uuids, [$orig_uuid], "original uuid in previous_uuids");
};

# ---- multiple retries accumulate previous uuids ----
subtest 'multiple retries accumulate previous_uuids' => sub {
    my $job = Test2::Harness2::Run::Job->new(run_id => 'run-1');

    my $uuid0 = $job->uuid;
    $job->retry();
    my $uuid1 = $job->uuid;
    $job->retry();
    my $uuid2 = $job->uuid;
    $job->retry();

    is($job->try_num, 3, "try_num is 3 after three retries");
    is(
        $job->previous_uuids, [$uuid0, $uuid1, $uuid2],
        "all three previous UUIDs tracked in order"
    );
    isnt($job->uuid, $uuid2, "current uuid differs from last previous uuid");
};

# ---- test_file attribute stored ----
subtest 'test_file attribute stored' => sub {
    # test_file is an opaque object from the caller's perspective here;
    # we just verify it is stored and retrievable.
    my $fake_tf = bless {file => 't/foo.t'}, 'FakeTestFile';

    my $job = Test2::Harness2::Run::Job->new(
        run_id    => 'run-1',
        test_file => $fake_tf,
    );

    is($job->test_file, $fake_tf, "test_file object stored and returned");
};

done_testing;

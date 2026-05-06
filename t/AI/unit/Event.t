use Test2::V0;

use Test2::Harness2::Event;

subtest 'constructor accepts no required keys' => sub {
    my $ok = eval { Test2::Harness2::Event->new(facet_data => {}); 1 };
    ok($ok, "constructs without event_id (which is no longer a required attribute)");

    my $bare = Test2::Harness2::Event->new;
    ok($bare, "constructs with no args at all");
    ref_ok($bare->facet_data, 'HASH', "facet_data defaults to {}");
};

subtest 'basic construction' => sub {
    my $event = Test2::Harness2::Event->new(
        facet_data => {
            info  => [{details => 'hello'}],
            trace => {stamp => 12345.678, pid => 999, tid => 1},
        },
    );

    ok($event, "created event");
    is($event->stamp, 12345.678, "stamp accessor reads trace.stamp");
    is($event->pid,   999,       "pid accessor reads trace.pid");
    is($event->tid,   1,         "tid accessor reads trace.tid");
    is($event->facet_data->{info}[0]{details}, 'hello', "facet data set");
    is($event->event_id, undef, "event_id accessor returns undef post-refactor");
};

subtest 'identifier accessors read canonical homes' => sub {
    my $event = Test2::Harness2::Event->new(
        facet_data => {
            harness => {
                run_id  => 'r1',
                job_id  => 'j1',
                job_try => 2,
            },
        },
    );

    is($event->run_id,  'r1', "run_id from harness facet");
    is($event->job_id,  'j1', "job_id from harness facet");
    is($event->job_try, 2,    "job_try from harness facet");
};

subtest 'TO_JSON strips empty facets' => sub {
    my $event = Test2::Harness2::Event->new(
        facet_data => {
            info    => [{details => 'test'}],
            harness => {},                  # empty hash
            errors  => [],                  # empty array
            trace   => {pid => 1},          # non-empty
        },
    );

    my $hash = $event->TO_JSON;
    ref_ok($hash, 'HASH', "TO_JSON returns hashref");
    ok(!exists $hash->{json}, "json key stripped from TO_JSON");
    ok(exists $hash->{facet_data}, "facet_data present");
    ok(exists $hash->{facet_data}{info},    "non-empty info kept");
    ok(exists $hash->{facet_data}{trace},   "non-empty trace kept");
    ok(!exists $hash->{facet_data}{harness}, "empty harness facet stripped");
    ok(!exists $hash->{facet_data}{errors},  "empty errors facet stripped");
};

done_testing;

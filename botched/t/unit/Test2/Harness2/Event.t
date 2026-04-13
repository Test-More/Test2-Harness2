use Test2::V0;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::JSON qw/decode_json/;

# ---- Basic construction ----
subtest 'basic construction' => sub {
    require Test2::Harness2::Event;

    my $before = time();
    my $e      = Test2::Harness2::Event->new(
        facet_data => {assert => {pass => 1, details => 'ok'}},
        run_id     => 'run-1',
        job_id     => 'job-1',
        job_try    => 0,
    );
    my $after = time();

    ok($e->event_id,         "event_id auto-generated");
    ok($e->stamp,            "stamp auto-set");
    ok($e->stamp >= $before, "stamp is >= before");
    ok($e->stamp <= $after,  "stamp is <= after");
    is($e->run_id,  'run-1', "run_id preserved");
    is($e->job_id,  'job-1', "job_id preserved");
    is($e->job_try, 0,       "job_try preserved");

    # facet_data preserved
    is($e->facet_data->{assert}{pass}, 1, "facet_data preserved");
};

# ---- event_id supplied ----
subtest 'event_id supplied' => sub {
    require Test2::Harness2::Event;

    my $e = Test2::Harness2::Event->new(
        facet_data => {},
        event_id   => 'my-event-id',
        run_id     => 'run-2',
        job_id     => 'job-2',
        job_try    => 1,
        stamp      => 12345.0,
    );

    is($e->event_id, 'my-event-id', "supplied event_id preserved");
    is($e->stamp,    12345.0,       "supplied stamp preserved");
};

# ---- harness facet auto-populated ----
subtest 'harness facet auto-populated' => sub {
    require Test2::Harness2::Event;

    my $e = Test2::Harness2::Event->new(
        facet_data => {},
        run_id     => 'run-3',
        job_id     => 'job-3',
        job_try    => 2,
        stamp      => 99999.5,
    );

    my $harness = $e->facet_data->{harness};
    ok($harness, "harness facet present in facet_data");
    is($harness->{event_id}, $e->event_id, "harness.event_id matches");
    is($harness->{run_id},   'run-3',      "harness.run_id populated");
    is($harness->{job_id},   'job-3',      "harness.job_id populated");
    is($harness->{job_try},  2,            "harness.job_try populated");
    is($harness->{stamp},    99999.5,      "harness.stamp populated");
};

# ---- TO_JSON excludes internal fields ----
subtest 'TO_JSON excludes internal fields' => sub {
    require Test2::Harness2::Event;

    my $json_key      = Test2::Harness2::Event::JSON();
    my $processed_key = Test2::Harness2::Event::PROCESSED();

    my $e = Test2::Harness2::Event->new(
        facet_data => {info => [{tag => 'NOTE', details => 'hi'}]},
        run_id     => 'run-4',
        job_id     => 'job-4',
        job_try    => 0,
    );

    # trigger json caching
    $e->as_json();

    my $h = $e->TO_JSON();
    ok(!exists $h->{$json_key},      "json key excluded from TO_JSON");
    ok(!exists $h->{$processed_key}, "processed key excluded from TO_JSON");
    ok($h->{facet_data},             "facet_data present in TO_JSON output");
};

# ---- JSON serialization roundtrip ----
subtest 'JSON roundtrip via as_json' => sub {
    require Test2::Harness2::Event;

    my $e = Test2::Harness2::Event->new(
        facet_data => {assert => {pass => 1, details => 'roundtrip'}},
        run_id     => 'run-5',
        job_id     => 'job-5',
        job_try    => 0,
        stamp      => 11111.1,
    );

    my $json1 = $e->as_json();
    my $json2 = $e->as_json();

    ok($json1, "as_json returns a string");
    is($json1, $json2, "as_json is cached (same string reference result)");

    my $decoded = decode_json($json1);
    is($decoded->{run_id},  'run-5', "run_id round-trips");
    is($decoded->{job_id},  'job-5', "job_id round-trips");
    is($decoded->{job_try}, 0,       "job_try round-trips");
    is($decoded->{stamp},   11111.1, "stamp round-trips");

    ok(!exists $decoded->{json},      "json field absent from serialized JSON");
    ok(!exists $decoded->{processed}, "processed field absent from serialized JSON");
};

# ---- as_json caching behavior ----
subtest 'as_json caching' => sub {
    require Test2::Harness2::Event;

    my $e = Test2::Harness2::Event->new(
        facet_data => {},
        run_id     => 'run-6',
        job_id     => 'job-6',
        job_try    => 0,
    );

    my $j1 = $e->as_json();
    my $j2 = $e->as_json();
    is(\$j1, \$j2, "as_json returns same scalar reference on second call (cached)");
};

done_testing;

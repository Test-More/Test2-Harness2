use Test2::V0;

use Test2::Harness2::Event;
use Test2::Harness2::Util::JSON qw/decode_json/;

subtest defaults => sub {
    my $e = Test2::Harness2::Event->new;
    is($e->facet_data, {});
    is($e->stream_id,  undef);
    is($e->event_id,   undef);
    is($e->stamp,      undef);
};

subtest attrs => sub {
    my $e = Test2::Harness2::Event->new(
        facet_data => {harness => {kind => 'lifecycle'}},
        stream_id  => 'events',
        event_id   => 'abc',
        stamp      => 1234.5,
    );
    is($e->stream_id, 'events');
    is($e->event_id,  'abc');
    is($e->stamp,     1234.5);
    is($e->facet_data->{harness}->{kind}, 'lifecycle');
};

subtest as_json_round_trip => sub {
    my $e = Test2::Harness2::Event->new(
        facet_data => {harness => {kind => 'k'}},
        stream_id  => 's',
        event_id   => 'e',
        stamp      => 1.5,
    );
    my $j = $e->as_json;
    my $d = decode_json($j);
    is($d->{stream_id}, 's');
    is($d->{event_id},  'e');
    is($d->{stamp},     1.5);
    is($d->{facet_data}->{harness}->{kind}, 'k');
};

subtest empty_facets_stripped => sub {
    my $e = Test2::Harness2::Event->new(
        facet_data => {
            harness => {kind => 'k'},
            empty   => {},
            list    => [],
            kept    => [1, 2],
        },
    );
    my $d = decode_json($e->as_json);
    ok(!exists $d->{facet_data}->{empty}, 'empty hash dropped');
    ok(!exists $d->{facet_data}->{list},  'empty array dropped');
    is($d->{facet_data}->{kept}, [1, 2]);
};

subtest json_cache => sub {
    my $e = Test2::Harness2::Event->new(facet_data => {harness => {a => 1}});
    my $j1 = $e->as_json;
    $e->facet_data->{harness}->{a} = 2;
    my $j2 = $e->as_json;
    is($j1, $j2, 'cached on first call');

    $e->clear_json_cache;
    my $j3 = $e->as_json;
    isnt($j1, $j3, 'cache cleared = fresh encode');
};

done_testing;

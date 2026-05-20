use Test2::V0;
use Test2::Harness2::Collector::Parser::IOParser;

my $p = Test2::Harness2::Collector::Parser::IOParser->new;
isa_ok($p, 'Test2::Harness2::Collector::Parser::IOParser');

subtest stdout_line => sub {
    my $e = $p->parse_io(stream => 'stdout', line => 'hello world');
    isa_ok($e, 'Test2::Harness2::Event');
    is($e->facet_data->{from_stream}{source},  'STDOUT', 'from_stream.source');
    is($e->facet_data->{from_stream}{details}, 'hello world');
    is($e->facet_data->{info}->[0]{tag},   'STDOUT');
    is($e->facet_data->{info}->[0]{debug}, 0, 'STDOUT info debug=0');
};

subtest stderr_line => sub {
    my $e = $p->parse_io(stream => 'stderr', line => 'oops');
    is($e->facet_data->{from_stream}{source},  'STDERR');
    is($e->facet_data->{info}->[0]{debug},      1, 'STDERR info debug=1');
};

subtest pre_decoded_event => sub {
    my $e = $p->parse_io(
        stream => 'stdout',
        event  => {facet_data => {assert => {pass => 1}}, event_id => 'sync-1'},
    );
    isa_ok($e, 'Test2::Harness2::Event');
    is($e->facet_data->{assert}{pass}, 1, 'facet preserved');
    ok(!exists $e->{event_id}, 'wire event_id stripped');
};

subtest compressed_stash => sub {
    my $e = $p->parse_io(
        stream     => 'stdout',
        event      => {facet_data => {info => [{tag => 'X'}]}},
        compressed => "BYTES",
    );
    is($e->{compressed_form}, 'BYTES', 'compressed stashed onto event');
};

subtest undef_returns_undef => sub {
    is($p->parse_io(stream => 'stdout'), undef, 'no line + no event => undef');
};

subtest stream_required => sub {
    like(dies { $p->parse_io(line => 'x') }, qr/stream/, 'missing stream croaks');
};

done_testing;

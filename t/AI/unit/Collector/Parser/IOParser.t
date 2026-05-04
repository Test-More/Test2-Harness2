use Test2::V0;

use Test2::Harness2::Collector::Parser::IOParser;
use Test2::Harness2::Event;

subtest 'construction' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    ok($parser, "created parser");
};

subtest 'parse stdout' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $event  = $parser->parse_io(stream => 'stdout', line => 'hello');

    ok($event, "got event");
    isa_ok($event, 'Test2::Harness2::Event');

    my $fd = $event->facet_data;
    is($fd->{from_stream}{source},  'STDOUT', "source is STDOUT");
    is($fd->{from_stream}{details}, 'hello',  "details match");
    is($fd->{info}[0]{debug},       0,        "stdout not debug");
    is($fd->{info}[0]{tag},         'STDOUT', "tag matches stream");
};

subtest 'parse stderr' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $event  = $parser->parse_io(stream => 'stderr', line => 'err');

    my $fd = $event->facet_data;
    is($fd->{from_stream}{source}, 'STDERR', "source is STDERR");
    is($fd->{info}[0]{debug},      1,        "stderr is debug");
    is($fd->{info}[0]{tag},        'STDERR', "tag matches stream");
};

subtest 'returns undef for undef line' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $event  = $parser->parse_io(stream => 'stdout', line => undef);
    ok(!defined $event, "undef line returns undef");
};

subtest 'parse_io strips wire-level event_id and does not stamp identifier mirrors' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});

    # Pre-built event with a wire-level event_id like the collector's
    # decoded JSON-burst payload would arrive: top-level event_id is
    # used by the collector for STDOUT/STDERR sync matching, then
    # stripped before the event reaches the parser pipeline.
    my $event = $parser->parse_io(
        stream   => 'stdout',
        event    => {event_id => 'WIRE-SYNC-ID', facet_data => {}},
    );

    ok($event, "got event");
    is($event->{event_id}, undef, "wire-level event_id stripped from event hash");

    # No harness-facet identifier mirrors are populated at the parser.
    my $h = $event->facet_data->{harness};
    ok(!defined $h || !exists $h->{event_id}, "harness.event_id not set by parser");
    ok(!defined $h || !exists $h->{stamp},    "harness.stamp not set by parser");
    ok(!defined $h || !exists $h->{run_id},   "harness.run_id not set by parser");
    ok(!defined $h || !exists $h->{job_id},   "harness.job_id not set by parser");
    ok(!defined $h || !exists $h->{job_try},  "harness.job_try not set by parser");
};

subtest 'set_ipcm_info stores ipcm_info' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => {});
    my $ii     = {host => 'localhost'};
    $parser->set_ipcm_info($ii);
    is($parser->ipcm_info, $ii, 'ipcm_info stored via set_ipcm_info');
};

subtest 'ipcm_info is required at construction' => sub {
    my $ok  = eval { Test2::Harness2::Collector::Parser::IOParser->new(); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without ipcm_info');
    like($err, qr/ipcm_info/, 'error mentions ipcm_info');
};

done_testing;

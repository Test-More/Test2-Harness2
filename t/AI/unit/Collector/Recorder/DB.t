use Test2::V0;
use Test2::Harness2::Collector::Recorder::DB;

my $r = Test2::Harness2::Collector::Recorder::DB->new;
isa_ok($r, 'Test2::Harness2::Collector::Recorder::DB');

for my $method (qw/record_event record_state record_exit record_artifact finalize/) {
    like(
        dies { $r->$method },
        qr/not yet implemented/,
        "$method croaks 'not yet implemented'",
    );
}

done_testing;

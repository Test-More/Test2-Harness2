use Test2::V0;
use Atomic::Pipe;
use Test2::Harness2::Util::EventEmitter;
use Test2::Harness2::Util::JSON qw/decode_json/;

subtest emit_event_basic => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $e = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);
    my $id = $e->emit_event(kind => 'lifecycle', note => 'hi');
    ok($id, 'returned id');

    my (undef, $msg) = $r->get_line_burst_or_data;
    my $event = decode_json($msg);
    is($event->{facet_data}->{harness}->{kind}, 'lifecycle');
    is($event->{facet_data}->{harness}->{note}, 'hi');
    is($event->{event_id}, $id);
};

subtest emit_raw => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $e = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);
    my $id = $e->emit_raw({facet_data => {info => [{tag => 'NOTE', details => 'x'}]}});
    my (undef, $msg) = $r->get_line_burst_or_data;
    my $event = decode_json($msg);
    is($event->{facet_data}->{info}->[0]->{tag}, 'NOTE');
    is($event->{event_id}, $id);
};

subtest sync_marker => sub {
    my ($r1, $w1) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($r2, $w2) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $e = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe => $w1,
        stderr_pipe => $w2,
    );
    my $id = $e->emit_event(kind => 'lifecycle');
    my (undef, $out_msg) = $r1->get_line_burst_or_data;
    my (undef, $err_msg) = $r2->get_line_burst_or_data;
    my $stdout = decode_json($out_msg);
    my $stderr = decode_json($err_msg);
    is($stdout->{event_id}, $id);
    is($stderr->{event_id}, $id);
};

subtest no_sync_when_no_stderr => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $e = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe => $w,
        stderr_pipe => undef,
    );
    my $id = $e->emit_event(kind => 'lifecycle');
    ok($id, 'still got an id');
    my (undef, $msg) = $r->get_line_burst_or_data;
    ok($msg, 'got stdout burst');
};

done_testing;

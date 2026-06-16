use Test2::V0;
use v5.38;

use File::Temp ();
use IO::Select;
use Time::HiRes qw/sleep/;

use Test2::Collector::Util::Socket qw/open_unix_listen connect_unix write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Test2::Harness2::Runner::Monitor;

# The runner-side monitor folds the transition messages a collector's reporter
# streams (start/harness_collector, harness_state_transition,
# harness_final_state, harness_collector_finalized) into per-collector state,
# keyed on the collector uuid. The proxy/run_uuid fan-out of the 2.0b reference
# is intentionally NOT implemented (single runner.socket, no per-run filtering),
# so those assertions are skipped here.

# --- feed already-decoded transition payloads ---

sub payload_for ($facet, %collector) {
    my $fd = {%$facet, harness_collector => {%collector}};
    return {facet_data => $fd};
}

sub feed_start ($mon, %c)        { $mon->feed(payload_for({harness_state_transition => {state => 'starting', stamp => 1}}, %c)) }
sub feed_trans ($mon, $s, $uuid) { $mon->feed(payload_for({harness_state_transition => {state => $s, stamp => 1}}, uuid => $uuid)) }
sub feed_final ($mon, $uuid, $p) { $mon->feed(payload_for({harness_final_state => {pass => $p, fail_count => $p ? 0 : 1}}, uuid => $uuid)) }
sub feed_fin   ($mon, $uuid)     { $mon->feed(payload_for({harness_collector_finalized => {stamp => 1}}, uuid => $uuid)) }

sub new_monitor () { Test2::Harness2::Runner::Monitor->new }

# Build a transition frame (a self-contained zstd frame of a JSON event stamped
# with a harness_collector identity facet) the way a real reporter would.
sub frame_for ($facet, %collector) {
    my $fd = {%$facet, harness_collector => {%collector}};
    return compress_blob(encode_json({facet_data => $fd}));
}

subtest empty => sub {
    my $mon = new_monitor();
    is([$mon->tests],      [], "no tests yet");
    is([$mon->services],   [], "no services yet");
    is([$mon->collectors], [], "no collectors yet");
};

subtest tracks_tests_and_services => sub {
    my $mon = new_monitor();
    feed_start($mon, uuid => 'T1', name => 't/foo.t', events_file => '/tmp/foo.jsonl.zst', try => 1);
    feed_start($mon, uuid => 'S1', name => 'stage-base');    # no try => service

    is([sort $mon->tests],    ['T1'], "T1 categorized as a test (has try)");
    is([sort $mon->services], ['S1'], "S1 categorized as a service (no try)");

    my $t = $mon->collector('T1');
    is($t->{name},              't/foo.t',            "test name tracked");
    is($t->{events_file},       '/tmp/foo.jsonl.zst', "events file tracked");
    is($t->{try},               1,                    "try tracked");
    is($t->{status},            'running',            "a started collector is running");
    is($mon->events_file('T1'), '/tmp/foo.jsonl.zst', "events_file query works");
    is($mon->status('T1'),      'running',            "status query works");
};

subtest new_collectors_delta => sub {
    my $mon = new_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    is([$mon->new_collectors], ['T1'], "first call reports the new collector");
    is([$mon->new_collectors], [],     "second call reports nothing new");

    feed_start($mon, uuid => 'T2', name => 't/b.t', events_file => '/tmp/b', try => 1);
    is([$mon->new_collectors], ['T2'], "only the newly-seen collector is reported");
};

subtest failing_and_diagnosing_deltas => sub {
    my $mon = new_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    feed_trans($mon, 'diagnosing', 'T1');
    feed_trans($mon, 'failing',    'T1');

    is([$mon->new_diagnosing], ['T1'], "diagnosing delta reports T1");
    is([$mon->new_failing],    ['T1'], "failing delta reports T1");
    is([$mon->new_failing],    [],     "failing delta drains");

    ok($mon->collector('T1')->{failing},    "failing flag latched");
    ok($mon->collector('T1')->{diagnosing}, "diagnosing flag latched");
};

subtest final_state_and_exits => sub {
    my $mon = new_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    feed_final($mon, 'T1', 1);
    feed_trans($mon, 'completed', 'T1');

    is($mon->final_state('T1')->{pass}, 1,          "final state stored");
    is($mon->collector('T1')->{status}, 'complete', "completed collector is complete");
    is([$mon->new_test_exits],          ['T1'],     "test exit delta reports the completed test");
    is([$mon->new_test_exits],          [],         "test exit delta drains");
};

subtest plain_collector_exited => sub {
    my $mon = new_monitor();
    feed_start($mon, uuid => 'S1', name => 'stage-base');
    feed_trans($mon, 'exited', 'S1');

    is($mon->collector('S1')->{status}, 'complete', "an exited plain collector is complete");
    is([$mon->new_completed],           ['S1'],     "completed delta reports the exited service");
    is([$mon->new_test_exits],          [],         "exited does not count as a test exit");
};

subtest finalized => sub {
    my $mon = new_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    feed_fin($mon, 'T1');

    is($mon->collector('T1')->{status}, 'finalized', "finalized collector status");
    is([$mon->new_finalized],           ['T1'],      "finalized delta reports T1");
};

subtest tracks_run_uuid => sub {
    my $mon = new_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-1');
    feed_start($mon, uuid => 'G1', name => 'stage-base');    # no run_uuid

    is($mon->collector('T1')->{run_uuid}, 'RUN-1', "run_uuid tracked from the start message");
    is($mon->collector('G1')->{run_uuid}, undef,   "a collector with no run_uuid has none");
};

# --- wire drive: frames over a real unix socket, decoded and fed via feed_frame
# (the same path the runner takes off Role::Service, minus the role plumbing) ---

subtest feed_frame_decodes_and_folds => sub {
    my $mon = new_monitor();

    my $payload = $mon->feed_frame(frame_for(
        {harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1,
    ));

    is($payload->{facet_data}{harness_collector}{uuid}, 'T1', "feed_frame returns the decoded payload");
    is([$mon->tests], ['T1'], "feed_frame folded the transition into state");

    is($mon->feed_frame(compress_blob(encode_json({facet_data => {}}))), undef,
        "a frame with no collector identity is ignored");
};

subtest full_lifecycle_over_socket => sub {
    my $dir  = File::Temp::tempdir(CLEANUP => 1);
    my $path = "$dir/runner.socket";

    # The runner side owns the listening socket (Role::Service does this for the
    # real runner); a collector reporter connects out and streams frames.
    my $listen = open_unix_listen($path);
    $listen->blocking(0);

    my $reporter = connect_unix($path);

    # Accept the reporter's connection.
    my $conn;
    for (1 .. 200) {
        $conn = $listen->accept and last;
        sleep 0.01;
    }
    ok($conn, "runner accepted the reporter connection");
    $conn->blocking(0);

    my $fb  = Test2::Collector::Util::Zstd::FrameBuffer->new;
    my $mon = new_monitor();

    # Drain whatever frames are readable into the monitor (mirrors the runner's
    # service_io -> service_transition -> monitor->feed path).
    my $drain = sub {
        my $sel = IO::Select->new($conn);
        for (1 .. 50) {
            last unless $sel->can_read(0.05);
            my $buf = '';
            my $n   = sysread($conn, $buf, 65536);
            last unless $n;
            $fb->push_bytes($buf);
        }
        for my $rec ($fb->drain) {
            $mon->feed(decode_json($rec->{payload}));
        }
    };

    # Stream the high-value transition set, one frame at a time, the way a real
    # collector's reporter does over its single connection.
    write_frame($reporter, frame_for(
        {harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'C1', name => 't/x.t', events_file => "$dir/events.jsonl.zst", try => 1, run_uuid => 'RUN-9',
    ));
    $drain->();
    is([$mon->tests], ['C1'], "start frame folded over the socket");
    is($mon->collector('C1')->{events_file}, "$dir/events.jsonl.zst", "events_file carried on the start frame");
    is($mon->collector('C1')->{run_uuid},    'RUN-9',                 "run_uuid carried on the start frame");

    write_frame($reporter, frame_for({harness_state_transition => {state => 'failing',    stamp => 1}}, uuid => 'C1'));
    write_frame($reporter, frame_for({harness_state_transition => {state => 'diagnosing', stamp => 1}}, uuid => 'C1'));
    write_frame($reporter, frame_for({harness_final_state => {pass => 0, fail_count => 2}},             uuid => 'C1'));
    write_frame($reporter, frame_for({harness_state_transition => {state => 'completed',  stamp => 1}}, uuid => 'C1'));
    write_frame($reporter, frame_for({harness_collector_finalized => {stamp => 1}},                     uuid => 'C1'));
    $drain->();

    ok($mon->collector('C1')->{failing},    "failing folded over the socket");
    ok($mon->collector('C1')->{diagnosing}, "diagnosing folded over the socket");
    is($mon->final_state('C1')->{pass}, 0, "final_state folded over the socket");
    is($mon->collector('C1')->{status}, 'finalized', "finalized status folded over the socket");
    is([$mon->new_failing],    ['C1'], "failing change-list captured the socket-driven transition");
    is([$mon->new_test_exits], ['C1'], "test-exit change-list captured the socket-driven completion");
    is([$mon->new_finalized],  ['C1'], "finalized change-list captured the socket-driven finalize");

    close($reporter);
    close($conn);
    close($listen);
};

done_testing;

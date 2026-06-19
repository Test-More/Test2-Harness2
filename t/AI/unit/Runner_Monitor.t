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
use Test2::Harness2::Role::Service::Connection();

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

# --- chunk 6.1: per-run routing -----------------------------------------------
#
# The runner stamps a test collector's run_uuid from the run's run_id, so the two
# identifiers are the same value and a single key routes both collector
# transitions (keyed on run_uuid) and runner-originated job mutations (keyed on
# run_id). Messages with no run association belong to a shared global bucket.

sub feed_job ($mon, $job_id, $state, %extra) {
    $mon->feed({facet_data => {harness_runner_job => {job_id => $job_id, state => $state, %extra}}});
}

subtest run_for_payload => sub {
    my $mon = new_monitor();

    # A collector start carries run_uuid directly.
    my $start = payload_for(
        {harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-A',
    );
    is($mon->run_for_payload($start), 'RUN-A', "collector start resolves to its run_uuid");
    $mon->feed($start);

    # A later transition for the same collector carries only the uuid; the run is
    # resolved against the tracked collector.
    my $later = payload_for({harness_state_transition => {state => 'completed', stamp => 1}}, uuid => 'T1');
    is($mon->run_for_payload($later), 'RUN-A', "uuid-only transition resolves run via tracked collector");

    # A runner-originated job mutation carries run_id.
    my $job = {facet_data => {harness_runner_job => {job_id => 'J1', state => 'dispatched', run_id => 'RUN-B'}}};
    is($mon->run_for_payload($job), 'RUN-B', "job mutation resolves to its run_id");

    # A run-less message (the runner's own / a stage lifecycle transition).
    my $global = payload_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'G1', name => 'stage-base');
    is($mon->run_for_payload($global), undef, "a collector with no run_uuid is global (undef)");
};

subtest filtered_snapshot => sub {
    my $mon = new_monitor();

    feed_start($mon, uuid => 'TA', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-A');
    feed_start($mon, uuid => 'TB', name => 't/b.t', events_file => '/tmp/b', try => 1, run_uuid => 'RUN-B');
    feed_start($mon, uuid => 'GS', name => 'stage-base');    # global, no run_uuid

    feed_job($mon, 'JA', 'dispatched', run_id => 'RUN-A', file => 't/a.t');
    feed_job($mon, 'JB', 'dispatched', run_id => 'RUN-B', file => 't/b.t');
    feed_job($mon, 'JG', 'dispatched');                     # global, no run_id

    my $all = $mon->snapshot;
    is([sort keys %{$all->{collectors}}], [qw/GS TA TB/], "unfiltered snapshot has every collector");
    is([sort keys %{$all->{jobs}}],       [qw/JA JB JG/], "unfiltered snapshot has every job");

    my $a = $mon->snapshot('RUN-A');
    is([sort keys %{$a->{collectors}}], [qw/GS TA/], "RUN-A snapshot = RUN-A collectors + global");
    is([sort keys %{$a->{jobs}}],       [qw/JA JG/], "RUN-A snapshot = RUN-A jobs + global");

    my $b = $mon->snapshot('RUN-B');
    is([sort keys %{$b->{collectors}}], [qw/GS TB/], "RUN-B snapshot = RUN-B collectors + global");
    is([sort keys %{$b->{jobs}}],       [qw/JB JG/], "RUN-B snapshot = RUN-B jobs + global");
};

# End-to-end routing through Role::Service: drive two runs' frames into a runner
# consumer and assert each subscriber's mirror only ever sees its own run + the
# global bucket, while a no-run-id subscriber sees everything.
subtest service_forward_routing => sub {
    require IO::Socket::UNIX;

    # A minimal consumer that folds transitions into a Runner::Monitor and routes
    # forwarded frames exactly as the real runner does (run_for_payload -> forward
    # to the matching subscribers).
    package Harness2::Test::RoutingService {
        use Test2::Harness2::Util::HashBase qw{<workdir +monitor};
        use Test2::Collector::Util::Zstd qw/compress_blob/;
        use Test2::Harness2::Util::JSON qw/encode_json/;
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::Service';
        sub name    { 'runner' }
        sub monitor { $_[0]->{monitor} //= Test2::Harness2::Runner::Monitor->new }

        sub request_handler_subscribe ($self, $payload, $conn) {
            $self->add_subscriber($conn, $payload->{run_id});
            return {ok => 1, snapshot => $self->monitor->snapshot($payload->{run_id})};
        }

        sub service_transition ($self, $payload, $frame, $conn) {
            $self->monitor->feed($payload);
            $self->forward_frame($frame, $self->monitor->run_for_payload($payload));
        }
    }

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $svc = Harness2::Test::RoutingService->new(workdir => $dir);
    $svc->start_service;

    my $path = $svc->service_socket_path;

    # Two run-scoped subscribers and one global subscriber connect + subscribe.
    # The listen backlog is small, so accept (service_io) after each connect.
    # Each subscriber speaks the service-channel protocol: a Connection (identity
    # on connect) then a subscribe request matched to its response by id.
    my %sub;
    for my $spec (['A', 'RUN-A'], ['B', 'RUN-B'], ['G', undef]) {
        my ($key, $run) = @$spec;
        my $c = connect_unix($path);
        $c->blocking(0);
        my $conn = Test2::Harness2::Role::Service::Connection->new(fh => $c, outbound => 1, my_identity => "sub-$key");
        my %args; $args{run_id} = $run if defined $run;
        my $id = $conn->send_request('subscribe', %args);
        $sub{$key} = {conn => $conn, id => $id, mon => new_monitor};
        $svc->service_io for 1 .. 3;
    }

    # Drain a subscriber: route the snapshot response into the mirror, fold any
    # forwarded transitions.
    my $drain_sub = sub ($s) {
        for my $ev ($s->{conn}->drain) {
            if ($ev->{kind} eq 'response' && $ev->{request_id} eq $s->{id}) {
                $s->{mon}->apply_snapshot($ev->{payload}{snapshot}) if $ev->{payload}{snapshot};
                $s->{got_reply} = 1;
            }
            elsif ($ev->{kind} eq 'transition') {
                $s->{mon}->feed($ev->{payload});
            }
        }
    };

    for my $key (qw/A B G/) {
        for (1 .. 40) {
            $svc->service_io;
            $drain_sub->($sub{$key});
            last if $sub{$key}{got_reply};
            sleep 0.01;
        }
        ok($sub{$key}{got_reply}, "$key got a subscribe reply");
    }

    # A test job reports its transitions on its own connection. Every connection
    # now identifies first (no reporter exemption) — a real collector does this via
    # the recorder preamble, with no_reply so the runner does NOT reply (an unread
    # reply would become a TCP-RST on close and drop the transition). We model that
    # here: send the identity (no_reply), then stream the transition.
    my $report = sub ($facet, %c) {
        my $rep = connect_unix($path);
        write_frame($rep, compress_blob(encode_json({identity => {name => "reporter:" . ($c{uuid} // 'x'), no_reply => 1}})));
        write_frame($rep, frame_for($facet, %c));
        # Pump until the service has actually READ + folded this transition before
        # closing the reporter. A fixed pump count races under load: closing while
        # the frame is still unread RSTs it (the very drop this test warns about),
        # which intermittently lost a collector under -j16 contention.
        my $uuid = $c{uuid};
        for (1 .. 500) {
            $svc->service_io;
            last if !defined($uuid) || (grep { $_ eq $uuid } $svc->monitor->collectors);
            sleep 0.005;
        }
        close($rep);
    };

    $report->({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'CA', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-A');
    $report->({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'CB', name => 't/b.t', events_file => '/tmp/b', try => 1, run_uuid => 'RUN-B');
    # A global (run-less) stage lifecycle transition.
    $report->({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'GS', name => 'stage-base');

    # Fold each subscriber's forwarded frames into its mirror, waiting until it has
    # received its expected collectors (A/B see their run + the global one; G sees
    # all three) rather than a fixed pump count that races under load.
    my %want = (A => 2, B => 2, G => 3);
    for my $key (qw/A B G/) {
        for (1 .. 500) {
            $svc->service_io;
            $drain_sub->($sub{$key});
            last if scalar($sub{$key}{mon}->collectors) >= $want{$key};
            sleep 0.005;
        }
    }

    is([sort $sub{A}{mon}->collectors], [qw/CA GS/], "run-A subscriber sees only run A + global");
    is([sort $sub{B}{mon}->collectors], [qw/CB GS/], "run-B subscriber sees only run B + global");
    is([sort $sub{G}{mon}->collectors], [qw/CA CB GS/], "global subscriber sees every run");

    $_->{conn}->close for values %sub;
    $svc->close_service;
};

done_testing;

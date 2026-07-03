use Test2::V0 -target => 'App::Yath2::Client';
use Test2::Tools::Spec;

use App::Yath2::Client;

use Test2::Harness2::Runner::Client();
use Test2::Harness2::Runner::Subscriber();
use Test2::Harness2::Runner::Monitor();

tests mode_default_and_validation => sub {
    my $client = App::Yath2::Client->new(workdir => '/tmp/wd');
    is($client->mode, 'transient', "mode defaults to transient");

    for my $mode (qw/transient attach start/) {
        ok(
            lives { App::Yath2::Client->new(workdir => '/tmp/wd', mode => $mode) },
            "mode '$mode' is valid",
        );
    }

    like(
        dies { App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'bogus') },
        qr/Invalid mode 'bogus'/,
        "an unknown mode is rejected",
    );

    like(
        dies { App::Yath2::Client->new() },
        qr/'workdir' is a required attribute/,
        "workdir is required",
    );
};

tests attach_runner_liveness => sub {
    # Attach mode: the client records a pre-existing pid, never reaps it, and
    # checks liveness with kill(0). $$ is always live; a never-allocated pid is not.
    my $client = App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'attach');

    is($client->owns_runner, 0, "attach client does not own the runner");

    $client->attach_runner($$);
    is($client->runner_pid,  $$, "attached the current pid");
    is($client->owns_runner, 0,  "still does not own the runner after attach");
    is($client->runner_gone, 0,  "a live attached pid is not gone");

    # reap/wait are no-ops for an unowned runner (must not block or reap).
    ok(lives { $client->reap_runner;    1 }, "reap_runner is a no-op in attach mode");
    ok(lives { $client->wait_for_runner; 1 }, "wait_for_runner is a no-op in attach mode");

    # signal_runner is a no-op for an unowned runner (must NOT signal the pid).
    my @killed;
    my $mock = Test2::Mock->new(class => 'App::Yath2::Client');
    # nothing to mock; just confirm it does not die and returns cleanly
    ok(lives { $client->signal_runner('TERM'); 1 }, "signal_runner is a no-op in attach mode");
};

tests transient_no_pid_is_gone => sub {
    # With no runner spawned yet, runner_gone is true (the submission liveness
    # check then reports the runner as unavailable).
    my $client = App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'transient');
    is($client->runner_gone, 1, "no runner pid means gone");

    # The default liveness check follows runner_gone.
    my $check = $client->liveness_check;
    is($check->(), 0, "default liveness check is false with no runner");
};

tests signal_handler_install_scope => sub {
    # install/remove are idempotent; both foreground modes trap, start mode does not.
    my $transient = App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'transient');

    local %SIG = %SIG;
    $transient->install_signal_handlers;
    ok(ref($SIG{INT}) eq 'CODE', "transient install set an INT handler");
    $transient->install_signal_handlers;    # idempotent
    $transient->remove_signal_handlers;
    ok(!ref($SIG{INT}), "remove cleared the INT handler");

    # #122: attach mode (yath run) MUST also install handlers so Ctrl-C is graceful
    # (flush renderers/logs, reset the terminal) instead of an instant fatal death.
    my $attach = App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'attach');
    delete $SIG{INT};
    $attach->install_signal_handlers;
    ok(ref($SIG{INT}) eq 'CODE', "attach mode installs signal handlers (#122)");
    $attach->remove_signal_handlers;
    ok(!ref($SIG{INT}), "attach remove cleared the INT handler");

    # start mode daemonizes and installs nothing here.
    my $start = App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'start');
    delete $SIG{INT};
    $start->install_signal_handlers;
    ok(!ref($SIG{INT}), "start mode installs no signal handlers");
};

tests terminate_queue_per_mode => sub {
    my @sent;
    my $mock = Test2::Mock->new(
        class    => 'Test2::Harness2::Runner::Client',
        override => [end_queue => sub { push @sent => 'end_queue'; return }],
    );

    my $transient = App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'transient');
    $transient->terminate_queue;
    is(\@sent, ['end_queue'], "transient terminate_queue sends end_queue");

    @sent = ();
    my $attach = App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'attach');
    $attach->terminate_queue;
    is(\@sent, [], "attach terminate_queue is a no-op (no end_queue)");
};

# Build a subscriber whose monitor is loaded from a fixed snapshot, so the
# state-query accessors can be exercised without a real socket.
sub client_with_state {
    my (%snapshot) = @_;

    my $mon = Test2::Harness2::Runner::Monitor->new;
    $mon->apply_snapshot({
        collectors => $snapshot{collectors} // {},
        jobs       => $snapshot{jobs}       // {},
        runs       => $snapshot{runs}       // {},
        run_health => $snapshot{run_health} // [],
    });

    my $sub = Test2::Harness2::Runner::Subscriber->new(workdir => '/tmp/wd');
    $sub->{+Test2::Harness2::Runner::Subscriber::MONITOR()} = $mon;

    my $client = App::Yath2::Client->new(workdir => '/tmp/wd');
    $client->{+App::Yath2::Client::SUBSCRIBER()} = $sub;

    return $client;
}

tests state_queries => sub {
    my $client = client_with_state(
        collectors => {
            'C-1' => {uuid => 'C-1', status => 'running',   events_file => '/wd/a.jsonl.zst', category => 'test'},
            'C-2' => {uuid => 'C-2', status => 'complete',  events_file => '/wd/b.jsonl.zst', category => 'test'},
            'C-3' => {uuid => 'C-3', status => 'finalized', events_file => '/wd/c.jsonl.zst', category => 'service'},
        },
        jobs => {
            'J-1' => {job_id => 'J-1', state => 'running', run_id => 'RUN-1'},
            'J-2' => {job_id => 'J-2', state => 'done',    run_id => 'RUN-1'},
            'J-3' => {job_id => 'J-3', state => 'done',    run_id => 'RUN-1'},
        },
        runs       => {'RUN-1' => {run_id => 'RUN-1'}},
        run_health => [{run_id => 'RUN-1', reason => 'post-pass failure'}],
    );

    isa_ok($client->monitor, ['Test2::Harness2::Runner::Monitor'], "monitor reaches the mirror");

    is([sort $client->collectors_in_status('running')],   ['C-1'],        "running collectors");
    is([sort $client->collectors_in_status('complete')],  ['C-2'],        "complete collectors");
    is([sort $client->collectors_in_status('finalized')], ['C-3'],        "finalized collectors");

    is([sort $client->jobs_in_state('running')], ['J-1'],          "jobs running");
    is([sort $client->jobs_in_state('done')],    ['J-2', 'J-3'],   "jobs done");
    is([sort $client->jobs_in_state('aborted')], [],               "no aborted jobs");

    is($client->events_file_for('C-2'), '/wd/b.jsonl.zst', "events_file_for a known collector");
    is($client->events_file_for('NOPE'), undef,            "events_file_for an unknown collector is undef");

    $client->{+App::Yath2::Client::RUN_ID()} = 'RUN-1';
    ok($client->run_done,           "run_done defaults to the client's run id");
    ok($client->run_done('RUN-1'),  "run_done is true for a finished run");
    ok(!$client->run_done('OTHER'), "run_done is false for an unknown run");

    is($client->run_health, [{run_id => 'RUN-1', reason => 'post-pass failure'}], "run_health surfaces health failures");
};

tests state_queries_no_subscriber => sub {
    # Without a subscriber the state accessors degrade gracefully.
    my $client = App::Yath2::Client->new(workdir => '/tmp/wd');
    is($client->monitor,                       undef, "monitor is undef with no subscriber");
    is([$client->jobs_in_state('done')],       [],    "jobs_in_state is empty with no subscriber");
    is([$client->collectors_in_status('running')], [], "collectors_in_status is empty with no subscriber");
    is($client->events_file_for('C-1'),        undef, "events_file_for is undef with no subscriber");
    is($client->run_done('RUN-1'),             0,     "run_done is false with no subscriber");
    is($client->run_health,                    [],    "run_health is empty with no subscriber");
};

tests submitter => sub {
    my $check = sub { 1 };

    my $client = App::Yath2::Client->new(
        workdir        => '/tmp/wd',
        liveness_check => $check,
    );

    is($client->workdir,        '/tmp/wd', "workdir accessor");
    ref_is($client->liveness_check, $check, "liveness_check accessor");

    my $submitter = $client->submitter;
    isa_ok($submitter, ['Test2::Harness2::Runner::Client'], "submitter is a Runner::Client");
    is($submitter->workdir, '/tmp/wd', "submitter bound to the workdir");
    ref_is($submitter->liveness_check, $check, "submitter got the liveness check");

    ref_is($client->submitter, $submitter, "submitter is cached");
};

tests subscriber_starts_undef => sub {
    my $client = App::Yath2::Client->new(workdir => '/tmp/wd');
    is($client->subscriber, undef, "no subscriber until connect_subscriber");
};

tests connect_subscriber_success => sub {
    # Avoid real sockets: intercept subscribe so the connect succeeds.
    my @subscribe_calls;
    my $mock = Test2::Mock->new(
        class    => 'Test2::Harness2::Runner::Subscriber',
        override => [subscribe => sub { push @subscribe_calls => $_[0]; 1 }],
    );

    my $client = App::Yath2::Client->new(workdir => '/tmp/wd');

    my $sub = $client->connect_subscriber(run_id => 'RUN-X');
    isa_ok($sub, ['Test2::Harness2::Runner::Subscriber'], "got a subscriber");
    is($sub->workdir, '/tmp/wd', "subscriber bound to the workdir");
    is(scalar(@subscribe_calls), 1, "subscribe was attempted once");

    ref_is($client->subscriber, $sub, "subscriber is cached after connect");
};

tests connect_subscriber_failure => sub {
    # A runner that never accepted: subscribe dies. connect_subscriber must warn
    # and return undef rather than propagating.
    my $mock = Test2::Mock->new(
        class    => 'Test2::Harness2::Runner::Subscriber',
        override => [subscribe => sub { die "no socket\n" }],
    );

    my $client = App::Yath2::Client->new(workdir => '/tmp/wd');

    my $warned;
    my $sub = do {
        local $SIG{__WARN__} = sub { $warned = $_[0] };
        $client->connect_subscriber;
    };

    is($sub, undef, "connect_subscriber returns undef on failure");
    is($client->subscriber, undef, "subscriber stays undef on failure");
    like($warned, qr/Could not subscribe to runner socket/, "warned about the failure");
};

done_testing;

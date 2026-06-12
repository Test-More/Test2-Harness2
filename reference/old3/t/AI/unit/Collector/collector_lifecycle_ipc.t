use Test2::V0;
use File::Temp qw/tempdir/;

# Unit-test the collector_start / collector_end IPC emissions added in
# M2 step 6. We instantiate a Collector in the parent process (no
# fork, no real IPC bus), then call the emission methods directly
# with a stubbed _ipc_client so we can inspect the kind / target /
# payload of each send.

use Test2::Harness2::Collector;

# Replace _ipc_client on a per-instance basis so other tests in the
# same process are unaffected.
sub install_fake_ipc_client {
    my ($self) = @_;

    my @sent;
    my $client = bless {sent => \@sent}, 't2h2::FakeIPCClient';
    $self->{_ipc_client}        = $client;
    $self->{_ipc_target_ready}  = {};
    $self->{_ipc_target_seen}   = {};

    return \@sent;
}

# Minimal IPC client that records every (target, content) sent.
{
    package t2h2::FakeIPCClient;

    sub set_send_blocking     { return }
    sub peer_active           { 1 }
    sub have_pending_sends    { 0 }
    sub drain_pending         { 0 }
    sub have_writable_handles { 0 }
    sub writable_handles      { () }
    sub disconnect            { return }
    sub try_send_message {
        my ($self, $target, $content) = @_;
        push @{$self->{sent}}, [$target, $content];
        return 1;
    }
    sub send_message { goto &try_send_message }
}

sub mk_job_collector {
    my %extra = @_;
    my $tmpdir = tempdir(CLEANUP => 1);
    return Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_run     => 'run-r0',
        ipc_parent  => 'run-r0',
        type        => 'Job',
        id          => 7,
        run_id      => 0,
        job_try     => 1,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
        child_pid   => 12345,
        spec        => {file => 'fake.t'},
        %extra,
    );
}

subtest 'job collector emits collector_start to ipc_run with full payload' => sub {
    my $c    = mk_job_collector();
    my $sent = install_fake_ipc_client($c);

    $c->_emit_collector_start({file => 'fake.t', collector_pid => $$});

    is(scalar @$sent, 1, 'one IPC message sent');

    my ($target, $content) = @{$sent->[0]};
    is($target, 'run-r0', 'sent to ipc_run');

    is($content->{kind}, 'collector_start', 'kind is collector_start');
    is($content->{type},          'Job', 'payload.type');
    is($content->{id},            7,     'payload.id');
    is($content->{run_id},        0,     'payload.run_id');
    is($content->{job_id},        7,     'payload.job_id is the id');
    is($content->{job_try},       1,     'payload.job_try');
    ok(!defined $content->{service_name}, 'service_name undef for jobs');

    is($content->{collector_pid}, $$,    'payload.collector_pid is our pid');
    is($content->{collected_pid}, 12345, 'payload.collected_pid');

    ok(defined $content->{started_at}, 'payload.started_at present');
    is($content->{spec}, {file => 'fake.t', collector_pid => $$}, 'spec hash forwarded');
};

subtest 'job collector emits collector_end to ipc_run with state hash' => sub {
    my $c    = mk_job_collector();
    my $sent = install_fake_ipc_client($c);

    # Job collectors carry an Auditor for state. Stub a tiny one with
    # the methods _auditor_final_state introspects.
    {
        package t2h2::FakeAuditor;
        sub new { bless {}, shift }
        sub pass            { 0 }
        sub fail_count      { 2 }
        sub pass_count      { 5 }
        sub assertion_count { 7 }
        sub exit            { 1 }
    }
    $c->{Test2::Harness2::Collector::AUDITOR()} = t2h2::FakeAuditor->new;

    # Simulate normal exit with a real wait status.
    my $child_exit = 0 << 8;    # exit 0
    $c->_emit_collector_end($child_exit);

    is(scalar @$sent, 1, 'one IPC message sent');

    my ($target, $content) = @{$sent->[0]};
    is($target, 'run-r0', 'sent to ipc_run');

    is($content->{kind},          'collector_end', 'kind is collector_end');
    is($content->{type},          'Job',           'payload.type');
    is($content->{id},            7,               'payload.id');
    is($content->{run_id},        0,               'payload.run_id');
    is($content->{job_id},        7,               'payload.job_id');
    is($content->{job_try},       1,               'payload.job_try');
    is($content->{collector_pid}, $$,              'payload.collector_pid');
    is($content->{collected_pid}, 12345,           'payload.collected_pid');
    is($content->{exit},          $child_exit,     'payload.exit raw waitstatus');

    ok(ref($content->{exit_decoded}) eq 'HASH', 'payload.exit_decoded is hashref');
    ok(defined $content->{ended_at}, 'payload.ended_at present');

    my $state = $content->{state};
    ok(ref($state) eq 'HASH', 'state is hashref');
    is($state->{exit}, $child_exit, 'state.exit set');
    ok(defined $state->{exit_decoded}, 'state.exit_decoded present');
    ok(defined $state->{ended_at},     'state.ended_at present');

    # Auditor-derived fields merged in.
    is($state->{fail_count}, 2, 'state.fail_count from auditor');
    is($state->{pass_count}, 5, 'state.pass_count from auditor');
    is($state->{assertion_count}, 7, 'state.assertion_count from auditor');
    is($state->{pass}, 0, 'state.pass from auditor');
};

subtest 'run-service collector emits to ipc_parent (= ipc_harness fallback)' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Run service collector: ipc_run undef, ipc_parent = ipc_harness.
    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        type        => 'Run',
        id          => 0,
        run_id      => 0,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
    my $sent = install_fake_ipc_client($c);

    $c->_emit_collector_start({});
    is(scalar @$sent, 1, 'one IPC message sent for run start');
    is($sent->[0][0], 'harness', 'run-collector start goes to ipc_parent (harness)');
    is($sent->[0][1]{kind}, 'collector_start', 'kind is collector_start');
    is($sent->[0][1]{type}, 'Run', 'payload.type=Run');
    ok(!defined $sent->[0][1]{job_id}, 'no job_id for Run');
    ok(!defined $sent->[0][1]{service_name}, 'no service_name for Run');
};

subtest 'global service collector emits to ipc_parent (=harness)' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    # Global service: ipc_run undef, ipc_parent=ipc_harness.
    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        type        => 'Service',
        id          => 'svc-foo',
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
    my $sent = install_fake_ipc_client($c);

    $c->_emit_collector_start({});
    $c->_emit_collector_end(undef);

    is(scalar @$sent, 2, 'one start + one end');

    is($sent->[0][0], 'harness', 'service start goes to ipc_parent');
    is($sent->[0][1]{kind}, 'collector_start');
    is($sent->[0][1]{type}, 'Service');
    is($sent->[0][1]{service_name}, 'svc-foo', 'service_name set for Service collectors');
    ok(!defined $sent->[0][1]{job_id},  'no job_id for Service');
    ok(!defined $sent->[0][1]{job_try}, 'no job_try for Service');

    is($sent->[1][0], 'harness', 'service end also goes to ipc_parent');
    is($sent->[1][1]{kind}, 'collector_end');
    is($sent->[1][1]{type}, 'Service');
    is($sent->[1][1]{service_name}, 'svc-foo');

    # state hash for non-Job collectors carries just the exit/timing
    # info -- no auditor data because there is no auditor.
    my $state = $sent->[1][1]{state};
    ok(ref($state) eq 'HASH', 'state hashref');
    ok(exists $state->{exit},          'state.exit present');
    ok(exists $state->{exit_decoded},  'state.exit_decoded present');
    ok(exists $state->{ended_at},      'state.ended_at present');
    ok(exists $state->{collector_pid}, 'state.collector_pid present');
    ok(!exists $state->{pass},         'no auditor-only fields');
};

subtest 'preload-spawned job: ipc_run takes priority over ipc_parent' => sub {
    # F7: a preload-spawned job has ipc_parent = preload bus,
    # ipc_run = the requesting run service. Lifecycle IPC routes to
    # ipc_run (run service), NOT ipc_parent (preload).
    my $tmpdir = tempdir(CLEANUP => 1);
    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'preload-svc',
        ipc_run     => 'run-r0',
        type        => 'Job',
        id          => 3,
        run_id      => 0,
        job_try     => 0,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
    my $sent = install_fake_ipc_client($c);

    $c->_emit_collector_start({});

    is(scalar @$sent, 1, 'one IPC message sent');
    is($sent->[0][0], 'run-r0', 'lifecycle goes to ipc_run, not ipc_parent (preload)');
};

done_testing;

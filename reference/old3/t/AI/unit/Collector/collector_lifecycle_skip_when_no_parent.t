use Test2::V0;
use File::Temp qw/tempdir/;

# F19: a collector with both ipc_parent AND ipc_run undef must NOT
# emit collector_start / collector_end IPC. Today only the harness's
# own collector matches that condition; this test exercises that
# skip path directly.

use Test2::Harness2::Collector;

# Stubbed IPC client: any send is a test failure (we should not be
# calling try_send_message at all when the lifecycle target resolves
# to undef).
{
    package t2h2::ForbidIPCClient;
    sub set_send_blocking     { return }
    sub peer_active           { 1 }
    sub have_pending_sends    { 0 }
    sub drain_pending         { 0 }
    sub have_writable_handles { 0 }
    sub writable_handles      { () }
    sub disconnect            { return }
    sub try_send_message {
        my ($self, $target, $content) = @_;
        die "unexpected IPC send to '$target' (kind=" . ($content->{kind} // '?') . ")\n";
    }
    sub send_message { goto &try_send_message }
}

sub mk_harness_collector {
    my $tmpdir = tempdir(CLEANUP => 1);
    return Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        # No ipc_parent. No ipc_run. This is what the harness service
        # passes to its own interpose collector.
        ipc_parent  => undef,
        ipc_run     => undef,
        type        => 'Service',
        id          => 'harness',
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
}

subtest 'no parent + no run -> no collector_start / collector_end IPC' => sub {
    my $c = mk_harness_collector();
    my $client = bless {}, 't2h2::ForbidIPCClient';
    $c->{_ipc_client} = $client;

    # The lifecycle target helper itself should report undef so the
    # caller (the emission methods) takes the early-return path.
    is($c->_lifecycle_ipc_target, undef, 'lifecycle target undef when both ipc_parent + ipc_run undef');

    # Emission methods take the early-return path. Both must complete
    # without invoking try_send_message (which would die).
    my $ok_start = eval { $c->_emit_collector_start({}); 1 };
    ok($ok_start, 'collector_start emit returned cleanly without sending');

    my $ok_end = eval { $c->_emit_collector_end(0); 1 };
    ok($ok_end, 'collector_end emit returned cleanly without sending');
};

subtest 'global service with ipc_parent set DOES emit (sanity check)' => sub {
    # Counter-check: a global service with ipc_parent=harness DOES
    # emit. If this stops working the skip test above is masking a
    # real bug, not the F19 rule.
    my $tmpdir = tempdir(CLEANUP => 1);
    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        ipc_run     => undef,
        type        => 'Service',
        id          => 'glob',
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
    my @sent;
    $c->{_ipc_client} = bless {sent => \@sent}, 't2h2::CaptureIPCClient';
    {
        package t2h2::CaptureIPCClient;
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

    is($c->_lifecycle_ipc_target, 'harness', 'global service routes to ipc_parent');

    $c->_emit_collector_start({});
    is(scalar @sent, 1, 'global service DID emit collector_start');
};

done_testing;

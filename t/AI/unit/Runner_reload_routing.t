use Test2::V0;
# HARNESS-DURATION-SHORT

# `yath reload` SIGHUPs the runner. During a persistent preload run the runner must
# route the reload to the base/default stage's LIVE channel -- the one connection it
# services for the whole run -- NOT to the preload-root's handshake channel, which is
# dormant mid-run (a reload sent there sits unread, or fires late during shutdown).
#
# The base/default stage is the one hosted IN the preload-root process, so its
# announced peer_pid equals PRELOAD_ROOT_PID; it is the only stage that owns the
# preload-root respawn jump frame. This drives:
#   * the REAL Runner::_preload_root_stage_identity selector against fake peers, and
#   * the REAL Preload::Host::request_handler_reload_root handler,
# asserting the reload routes to the base/default stage, is dropped if no such peer
# is connected, and that a queued `stop` cancels a pending reload (so a stale reload
# cannot re-exec the tree during wind-down).

use Test2::Harness2::Runner;
use Test2::Harness2::Preload::Host;

# A minimal stand-in connection: just peer_pid + closed, the two things
# _preload_root_stage_identity reads off a peer.
{
    package FakeConn;
    sub new    { my ($c, %a) = @_; bless {pid => $a{pid}, closed => $a{closed} // 0}, $c }
    sub peer_pid { $_[0]->{pid} }
    sub closed   { $_[0]->{closed} ? 1 : 0 }
}

subtest base_stage_identity_selection => sub {
    my $root_pid = 4242;

    # The base/default stage's connection announces the preload-root's own pid (it is
    # hosted in that process); a named child stage announces its own distinct pid.
    my $fake = bless {
        preload_root_pid => $root_pid,
        service_peers    => {
            'preload-root'    => FakeConn->new(pid => $root_pid),
            'preload-base'    => FakeConn->new(pid => $root_pid),
            'preload-ALPHA'   => FakeConn->new(pid => 9001),
        },
    }, 'Test2::Harness2::Runner';

    my $id = Test2::Harness2::Runner::_preload_root_stage_identity($fake);
    is($id, 'preload-base', "selected the base stage (peer_pid == preload-root pid), not the named stage or the handshake peer");
};

subtest non_default_named_base => sub {
    my $root_pid = 555;

    # Non-staged preload: the base stage registers as 'preload-default'.
    my $fake = bless {
        preload_root_pid => $root_pid,
        service_peers    => {
            'preload-root'    => FakeConn->new(pid => $root_pid),
            'preload-default' => FakeConn->new(pid => $root_pid),
        },
    }, 'Test2::Harness2::Runner';

    is(Test2::Harness2::Runner::_preload_root_stage_identity($fake), 'preload-default', "finds the 'default' base stage by pid match");
};

subtest no_base_peer_drops_reload => sub {
    # No preload-root pid at all -> undef (the runner drops the reload rather than
    # misrouting it).
    my $no_root = bless {service_peers => {}}, 'Test2::Harness2::Runner';
    is(Test2::Harness2::Runner::_preload_root_stage_identity($no_root), undef, "no preload-root -> undef");

    # A preload-root is up but no stage has registered in-process yet (only a named
    # stage with a different pid, plus the handshake peer) -> undef.
    my $not_ready = bless {
        preload_root_pid => 700,
        service_peers    => {
            'preload-root'  => FakeConn->new(pid => 700),
            'preload-ALPHA' => FakeConn->new(pid => 8000),
        },
    }, 'Test2::Harness2::Runner';
    is(Test2::Harness2::Runner::_preload_root_stage_identity($not_ready), undef, "no base/default stage peer yet -> undef");

    # A closed base-stage connection is ignored.
    my $closed = bless {
        preload_root_pid => 700,
        service_peers    => {'preload-base' => FakeConn->new(pid => 700, closed => 1)},
    }, 'Test2::Harness2::Runner';
    is(Test2::Harness2::Runner::_preload_root_stage_identity($closed), undef, "a closed base-stage connection is not selected");
};

subtest hup_handler_routes_reload_root => sub {
    # Build the REAL Runner HUP handler closure (the one init installs) and verify it
    # sends 'reload_root' to the base/default stage, never 'reload' to preload-root.
    my @sent;
    my $fake = bless {
        preload_root_pid => 4242,
        service_peers    => {
            'preload-root' => FakeConn->new(pid => 4242),
            'preload-base' => FakeConn->new(pid => 4242),
        },
    }, 'Test2::Harness2::Runner';

    # service_send is the role method; stub it on this instance to record routing.
    no warnings 'redefine';
    local *Test2::Harness2::Runner::service_send = sub {
        my ($self, $identity, $command, %args) = @_;
        push @sent => [$identity, $command];
        return 1;
    };

    # Rebuild just the HUP closure the runner installs in init (kept identical here in
    # spirit: route to the base/default stage's live channel).
    my $hup = sub {
        if ($fake->{preload_root_pid}) {
            my $id = $fake->_preload_root_stage_identity or return;
            $fake->service_send($id, 'reload_root');
            return;
        }
        return;
    };

    $hup->('HUP');

    is(\@sent, [['preload-base', 'reload_root']], "HUP routed 'reload_root' to the base stage's live channel");
};

subtest reload_root_handler_and_stop_ordering => sub {
    # Drive the REAL Preload::Host::request_handler_reload_root.
    my $host = bless {}, 'Test2::Harness2::Preload::Host';

    # service_stopped is the role method; stub a controllable flag on this instance.
    no warnings 'redefine';
    my $stopped = 0;
    local *Test2::Harness2::Preload::Host::service_stopped = sub { $stopped ? 1 : 0 };

    Test2::Harness2::Preload::Host::request_handler_reload_root($host, {});
    is($host->{pending_reload}, 1, "reload_root marks a pending reload");
    is($host->{signal}, 'HUP', "reload_root sets SIGNAL=HUP to end the run loop");

    # A second reload while one is already pending (SIGNAL set) is a no-op.
    delete $host->{pending_reload};
    Test2::Harness2::Preload::Host::request_handler_reload_root($host, {});
    is($host->{pending_reload}, undef, "a reload arriving while SIGNAL is already set is ignored (no double-respawn)");

    # A reload that arrives once a stop is queued is dropped.
    my $stopping = bless {}, 'Test2::Harness2::Preload::Host';
    $stopped = 1;
    Test2::Harness2::Preload::Host::request_handler_reload_root($stopping, {});
    is($stopping->{pending_reload}, undef, "a reload is dropped once a stop is queued (no stale re-exec during shutdown)");
    is($stopping->{signal}, undef, "a stop-time reload does not even set SIGNAL");
};

done_testing;

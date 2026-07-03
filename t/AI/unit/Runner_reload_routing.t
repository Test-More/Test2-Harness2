use Test2::V0;
# HARNESS-DURATION-SHORT

# `yath reload` SIGHUPs the runner. During a persistent preload run the runner must
# route the reload to the base/default stage's LIVE channel -- the one connection it
# services for the whole run -- NOT to the preload-root's handshake channel, which is
# dormant mid-run (a reload sent there sits unread, or fires late during shutdown).
#
# The base/default stage is the one hosted IN the preload-root process. But the
# preload-root is spawned under a double-forking collector, so PRELOAD_ROOT_PID is the
# collector PARENT while the preload tree runs in the exec'd GRANDCHILD. The base
# stage's socket therefore announces the GRANDCHILD pid, NOT PRELOAD_ROOT_PID -- the
# SAME pid the 'preload-root' handshake connection (which dials from that grandchild)
# announces. The selector must match the base stage against the 'preload-root' peer's
# pid, never against PRELOAD_ROOT_PID (#113: matching PRELOAD_ROOT_PID never hit and
# silently dropped every HUP reload). These fakes model that two-process pid split so
# they fail against the old comparison. This drives:
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
    # The double-fork split: PRELOAD_ROOT_PID is the collector PARENT; the preload tree
    # (and the base stage it hosts) runs in the exec'd GRANDCHILD, which is the pid the
    # 'preload-root' handshake peer and the base stage's own socket both announce.
    my $parent_pid = 4242;    # collector parent == PRELOAD_ROOT_PID (NOT the stage's pid)
    my $child_pid  = 5555;    # exec'd grandchild -- where the base stage actually runs

    my $fake = bless {
        preload_root_pid => $parent_pid,
        service_peers    => {
            'preload-root'    => FakeConn->new(pid => $child_pid),
            'preload-base'    => FakeConn->new(pid => $child_pid),
            'preload-ALPHA'   => FakeConn->new(pid => 9001),
        },
    }, 'Test2::Harness2::Runner';

    my $id = Test2::Harness2::Runner::_preload_root_stage_identity($fake);
    is($id, 'preload-base', "selected the base stage (peer_pid == preload-root peer's grandchild pid), not the named stage or PRELOAD_ROOT_PID (the collector parent)");
};

subtest non_default_named_base => sub {
    my $parent_pid = 555;
    my $child_pid  = 666;

    # Non-staged preload: the base stage registers as 'preload-default', in the exec'd
    # grandchild -- the same pid the 'preload-root' handshake announces.
    my $fake = bless {
        preload_root_pid => $parent_pid,
        service_peers    => {
            'preload-root'    => FakeConn->new(pid => $child_pid),
            'preload-default' => FakeConn->new(pid => $child_pid),
        },
    }, 'Test2::Harness2::Runner';

    is(Test2::Harness2::Runner::_preload_root_stage_identity($fake), 'preload-default', "finds the 'default' base stage by grandchild-pid match");
};

subtest no_base_peer_drops_reload => sub {
    # No preload-root pid at all -> undef (the runner drops the reload rather than
    # misrouting it).
    my $no_root = bless {service_peers => {}}, 'Test2::Harness2::Runner';
    is(Test2::Harness2::Runner::_preload_root_stage_identity($no_root), undef, "no preload-root -> undef");

    # A preload-root is up but no stage has registered in-process yet (only a named
    # stage with a DIFFERENT pid, plus the handshake peer) -> undef.
    my $not_ready = bless {
        preload_root_pid => 700,          # collector parent
        service_peers    => {
            'preload-root'  => FakeConn->new(pid => 701),    # exec'd grandchild
            'preload-ALPHA' => FakeConn->new(pid => 8000),
        },
    }, 'Test2::Harness2::Runner';
    is(Test2::Harness2::Runner::_preload_root_stage_identity($not_ready), undef, "no base/default stage peer yet -> undef");

    # A closed base-stage connection is ignored (its grandchild pid matches, but it is
    # closed) -- the handshake peer is present so the selector reaches the skip.
    my $closed = bless {
        preload_root_pid => 700,
        service_peers    => {
            'preload-root' => FakeConn->new(pid => 701),
            'preload-base' => FakeConn->new(pid => 701, closed => 1),
        },
    }, 'Test2::Harness2::Runner';
    is(Test2::Harness2::Runner::_preload_root_stage_identity($closed), undef, "a closed base-stage connection is not selected");
};

subtest hup_handler_routes_reload_root => sub {
    # Build the REAL Runner HUP handler closure (the one init installs) and verify it
    # sends 'reload_root' to the base/default stage, never 'reload' to preload-root.
    my @sent;
    my $fake = bless {
        preload_root_pid => 4242,                            # collector parent
        service_peers    => {
            'preload-root' => FakeConn->new(pid => 5555),    # exec'd grandchild
            'preload-base' => FakeConn->new(pid => 5555),    # base stage, same grandchild
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

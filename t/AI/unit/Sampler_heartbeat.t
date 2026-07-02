use Test2::V0;
use v5.38;

use Test2::Harness2::Service::Sampler;
use Test2::Harness2::Util qw/mono_time/;

# Ticket #138 finding (39): the 5%-bucket change-gating stopped sending updates
# once mem_pct pinned at 100, so a resource reading the raw mem_available (e.g.
# -R Memory=512mb) saw a FROZEN value while free memory collapsed -- the resource
# never deferred and the OOM killer fired. The fix is a max-staleness HEARTBEAT:
# even when neither rounded bucket changes, a snapshot is sent unconditionally
# once the last send is older than `heartbeat` seconds, so the raw fields are
# never staler than the heartbeat while a bucket is pinned.

# No collector event channel here: keep _emit_load_event an inert no-op so nothing
# is ever written to STDOUT (which would corrupt this test's own TAP stream)
# regardless of the runner driving this test.
delete $ENV{T2_COLLECTOR_PIPE_COUNT};

# A source whose sample() returns scripted snapshots in order.
package FakeSource {
    sub new    { bless {queue => $_[1]}, $_[0] }
    sub sample { return shift @{$_[0]->{queue}} }
}

# A connection that is always open (never closed), so service_tick reaches the
# send decision.
package FakeConn {
    sub new    { bless {}, $_[0] }
    sub closed { 0 }
}

# A Sampler subclass that records (instead of transmitting) each one-way send.
package RecordingSampler {
    use parent -norequire, 'Test2::Harness2::Service::Sampler';

    sub service_send {
        my ($self, $identity, $command, %args) = @_;
        push @{$self->{sent}} => {identity => $identity, command => $command, %args};
        return 1;    # a successful send: never trip stop_service
    }
}

use constant CONN         => Test2::Harness2::Service::Sampler::CONN();
use constant NEXT_AT      => Test2::Harness2::Service::Sampler::NEXT_AT();
use constant LAST_SENT_AT => Test2::Harness2::Service::Sampler::LAST_SENT_AT();

# All three mem_pct values round UP to the same bucket (100), so change-gating
# alone would suppress every send after the first -- but the raw mem_available
# COLLAPSES underneath. cpu_pct is constant so CPU never re-triggers either.
sub snaps {
    return (
        {cpu_pct => 50, mem_pct => 96, mem_available => 1000, mem_total => 8000, load_avg => [1, 1, 1], stamp => 1},
        {cpu_pct => 50, mem_pct => 97, mem_available => 500,  mem_total => 8000, load_avg => [1, 1, 1], stamp => 2},
        {cpu_pct => 50, mem_pct => 98, mem_available => 100,  mem_total => 8000, load_avg => [1, 1, 1], stamp => 3},
    );
}

subtest heartbeat_emits_within_window_despite_pinned_bucket => sub {
    my $s = RecordingSampler->new(
        workdir       => '/tmp',
        runner_socket => '/tmp/does-not-matter.sock',
        source        => FakeSource->new([snaps()]),
        heartbeat     => 2.0,
    );
    $s->{sent}    = [];
    $s->{+CONN()} = FakeConn->new;

    # (a) tick 1: the initial reading always sends.
    $s->{+NEXT_AT()} = 0;    # force the tick body to run
    $s->service_tick;
    is(scalar @{$s->{sent}}, 1, "tick 1 sends the initial reading");
    is($s->{sent}[0]{load}{mem_available}, 1000, "initial send carries mem_available 1000");
    is($s->{sent}[0]{load}{mem_pct}, 100, "reported mem_pct is the rounded bucket (100)");
    is($s->{sent}[0]{want_reply}, 0, "one-way send (want_reply => 0)");
    ok(defined $s->{+LAST_SENT_AT()}, "LAST_SENT_AT is set after a triggered send");
    my $after_first = $s->{+LAST_SENT_AT()};

    # (b) an immediate second tick with the bucket pinned at 100 sends NOTHING --
    # change-gating is preserved inside the heartbeat window.
    $s->{+NEXT_AT()} = 0;
    $s->service_tick;
    is(scalar @{$s->{sent}}, 1, "immediate tick 2 with a pinned bucket sends nothing");
    is($s->{+LAST_SENT_AT()}, $after_first, "a suppressed tick does not advance LAST_SENT_AT");

    # (c) once the heartbeat window has elapsed (backdate LAST_SENT_AT past it) a
    # tick sends unconditionally, and the snapshot carries the CURRENT collapsed
    # mem_available (100), NOT the frozen 1000.
    my $backdated = mono_time() - 100;
    $s->{+LAST_SENT_AT()} = $backdated;
    $s->{+NEXT_AT()}      = 0;
    $s->service_tick;
    is(scalar @{$s->{sent}}, 2, "a tick after the heartbeat window sends despite the pinned bucket");
    is($s->{sent}[1]{load}{mem_available}, 100, "heartbeat send carries the CURRENT collapsed mem_available (not 1000)");

    # (d) LAST_SENT_AT advances on the heartbeat send too.
    ok($s->{+LAST_SENT_AT()} > $backdated, "LAST_SENT_AT advances on a heartbeat send");
};

subtest heartbeat_defaults_to_2 => sub {
    my $s = Test2::Harness2::Service::Sampler->new(
        workdir       => '/tmp',
        runner_socket => '/tmp/does-not-matter.sock',
    );
    is($s->heartbeat, 2.0, "heartbeat defaults to 2.0 seconds");
};

done_testing;

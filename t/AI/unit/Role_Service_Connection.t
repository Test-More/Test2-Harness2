use Test2::V0;
use v5.38;

use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;

use Test2::Collector::Util::Socket qw/write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Role::Service::Connection;

my $PENDING = Test2::Harness2::Role::Service::Connection::PENDING();

# A connected pair of non-blocking unix sockets.
sub pair {
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    $_->blocking(0) for $a, $b;
    return ($a, $b);
}

sub conn {
    my ($fh, $id, $outbound) = @_;
    return Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        my_identity => $id,
        outbound    => $outbound // 0,
    );
}

# Drain both ends a few times so frames flow.
sub pump {
    my @conns = @_;
    my @events;
    for (1 .. 5) {
        push @events => map { [$_->my_identity, $_->drain] } @conns;
    }
    return @events;
}

subtest identity_exchange => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 1);
    my $b = conn($fb, 'beta', 0);

    ok(!$a->ready, "alpha not ready before exchange");

    # Interleave: alpha (dialer) already sent identity; beta (accepter) replies
    # only after it reads alpha's, so beta must drain before alpha can finish.
    for (1 .. 3) { $b->drain; $a->drain }

    ok($a->ready, "alpha ready after receiving beta's identity");
    ok($b->ready, "beta ready after receiving alpha's identity");
    is($a->identity, 'beta',  "alpha learned beta");
    is($b->identity, 'alpha', "beta learned alpha");

    # The identity handshake carries each peer's real pid; both ends run in this
    # process, so each learns $$.
    is($a->peer_pid, $$, "alpha learned beta's pid from the handshake");
    is($b->peer_pid, $$, "beta learned alpha's pid from the handshake");
};

subtest request_response_correlation => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 1);
    my $b = conn($fb, 'beta', 0);
    $_->drain for $a, $b, $a, $b;    # exchange identity

    my $id = $a->send_request('echo', msg => 'hi');
    ok($id, "send_request returned a request_id");

    my @bev = $b->drain;
    is(scalar(@bev), 1, "beta got one event");
    is(
        $bev[0],
        {kind => 'request', request_id => $id, command => 'echo', payload => {request_id => $id, command => 'echo', msg => 'hi'}},
        "request classified with id + command + args",
    );

    $b->send_response($id, {ok => 1, echoed => 'hi'});
    my @aev = $a->drain;
    is(scalar(@aev), 1, "alpha got one event");
    is($aev[0]{kind}, 'response', "it is a response");
    is($aev[0]{request_id}, $id, "matched by request_id");
    is($aev[0]{payload}{echoed}, 'hi', "carries the response payload");
};

subtest async_unordered_and_unmatched_response => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 1);
    my $b = conn($fb, 'beta', 0);
    $_->drain for $a, $b, $a, $b;

    # alpha fires two requests; beta answers the SECOND first (out of order).
    my $id1 = $a->send_request('one');
    my $id2 = $a->send_request('two');
    $b->drain;
    $b->send_response($id2, {n => 2});
    $b->send_response($id1, {n => 1});

    my %got = map { $_->{request_id} => $_->{payload}{n} } $a->drain;
    is(\%got, {$id1 => 1, $id2 => 2}, "responses matched by id regardless of order");

    # A response for an unknown id is discarded, not a strike, not delivered.
    $b->send_response('no-such-id', {n => 9});
    my @ev = $a->drain;
    is(\@ev, [], "unmatched response discarded");
    ok(!$a->closed, "unmatched response did not poison the connection");
};

subtest non_identity_first_is_bad => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 1);    # sends identity, waits for peer's

    # The peer sends a request instead of an identity first.
    write_frame($fb, compress_blob(encode_json({request => {request_id => 'x', command => 'echo'}})), 'raw');

    $a->drain;
    ok($a->closed, "a non-identity first frame drops the connection");
};

subtest transition_first_is_bad => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 0);    # accepter

    # There is no reporter exemption: a transition as the first frame (no identity)
    # is a bad connection, exactly like any other non-identity-first frame.
    # Collectors now identify first (via the recorder preamble), so a bare
    # transition-first connection no longer happens.
    write_frame($fb, compress_blob(encode_json({facet_data => {harness_collector => {uuid => 'U1'}}})), 'raw');

    my @ev = $a->drain;
    is(\@ev, [], "a transition-first connection yields no event");
    ok($a->closed, "a transition-first connection (no identity) is dropped as bad");
    ok(!defined $a->identity, "it never became an identified peer");
};

subtest three_bad_frames_after_ready => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 1);
    my $b = conn($fb, 'beta', 0);
    $_->drain for $a, $b, $a, $b;
    ok($a->ready, "ready");

    my $garbage = sub { write_frame($fb, compress_blob('not-json-at-all'), 'raw') };

    $garbage->();
    $a->drain;
    ok(!$a->closed, "one bad frame tolerated");

    # A valid frame resets the strike count.
    $b->send_request('ping');
    $a->drain;
    $garbage->() for 1 .. 2;
    $a->drain;
    ok(!$a->closed, "two bad frames (after a reset) still tolerated");

    $garbage->();
    $a->drain;
    ok($a->closed, "three consecutive bad frames close the connection");
};

# #134 finding 13: a zstd framing croak from FrameBuffer (garbage bytes on the
# socket) must NOT escape drain and kill the whole service. drain closes the
# desynced connection immediately (no 3-strike -- a corrupt zstd stream can never
# resync) while STILL returning the valid frames it decoded before the croak.
subtest garbage_bytes_survive_after_ready => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 1);
    my $b = conn($fb, 'beta', 0);
    $_->drain for $a, $b, $a, $b;    # identity exchange
    ok($a->ready, "ready");

    # One valid request frame immediately followed by raw (non-zstd) garbage, in a
    # single burst -- so both land in one drain pass.
    my $valid   = compress_blob(encode_json({request => {request_id => 'r1', command => 'echo', msg => 'hi'}}));
    my $garbage = 'GARBAGE!' x 64;    # not a valid zstd frame -> next_frame croaks
    syswrite($fb, $valid . $garbage) // die "syswrite: $!";

    my @ev;
    my $ok = eval { @ev = $a->drain; 1 };

    ok($ok, "drain did not throw despite the corrupt trailing frame");
    is(scalar(@ev), 1, "the valid frame decoded before the croak was still returned");
    is($ev[0]{kind}, 'request', "returned event is the request");
    is($ev[0]{command}, 'echo', "with the right command");
    ok($a->closed, "the desynced connection was closed immediately (no 3-strike)");
};

subtest garbage_bytes_as_first_frame => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 0);    # accepter, pending identity

    syswrite($fb, 'TOTAL GARBAGE!!!' x 16) // die "syswrite: $!";

    my @ev;
    my $ok = eval { @ev = $a->drain; 1 };

    ok($ok, "drain did not throw on first-byte garbage");
    is(\@ev, [], "no events from a corrupt first frame");
    ok($a->closed, "the connection was dropped as bad");
};

# #134 finding 106: a one-way request (want_reply => 0) must not leave a PENDING
# request-id behind, or a daemon-lifetime connection leaks sender-side memory. A
# default (two-way) request registers exactly one PENDING entry, cleared when its
# reply is drained.
subtest one_way_send_does_not_leak_pending => sub {
    my ($fa, $fb) = pair();
    my $a = conn($fa, 'alpha', 1);
    my $b = conn($fb, 'beta', 0);
    $_->drain for $a, $b, $a, $b;

    $a->send_request("x$_", want_reply => 0) for 1 .. 50;
    is(scalar keys %{$a->{$PENDING} // {}}, 0, "50 one-way sends leave PENDING empty");

    my $id = $a->send_request('needs_reply');
    is(scalar keys %{$a->{$PENDING} // {}}, 1, "a default (two-way) request registers exactly one PENDING entry");

    $b->drain;    # beta sees the requests
    $b->send_response($id, {ok => 1});
    $a->drain;    # alpha matches + clears
    is(scalar keys %{$a->{$PENDING} // {}}, 0, "PENDING cleared once the reply is drained");
};

done_testing;

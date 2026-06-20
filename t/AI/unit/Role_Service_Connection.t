use Test2::V0;
use v5.38;

use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;

use Test2::Collector::Util::Socket qw/write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Role::Service::Connection;

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

done_testing;

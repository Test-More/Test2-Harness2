use Test2::V0 -target => 'App::Yath2::Client';
use Test2::Tools::Spec;

use App::Yath2::Client;

use Test2::Harness2::Runner::Client();
use Test2::Harness2::Runner::Subscriber();

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

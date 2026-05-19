use Test2::V0;
use Test2::Harness2::PreloadService;

# Validation: missing fields warn (async receiver: no sync caller).
{
    my $svc = bless {}, 'Test2::Harness2::PreloadService';
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, @_ };

    $svc->request_handler_spawn_service({}, undef);
    like(\@warns, [match qr/missing 'class'/], 'missing class warned');

    @warns = ();
    $svc->request_handler_spawn_service({class => 'Foo'}, undef);
    like(\@warns, [match qr/missing 'peer_name'/], 'missing peer_name warned');

    @warns = ();
    $svc->request_handler_spawn_service(
        {class => 'Foo', peer_name => 'preload-foo-1'},
        undef,
    );
    like(\@warns, [match qr/missing 'spawn_id'/], 'missing spawn_id warned');

    @warns = ();
    $svc->request_handler_spawn_service(
        {class => 'Foo', peer_name => 'preload-foo-1', spawn_id => 42},
        undef,
    );
    like(\@warns, [match qr/missing 'notify_to'/], 'missing notify_to warned');
}

# Routing: run_on_general_message dispatches kind=spawn_service to the
# handler. Monkey-patch request_handler_spawn_service to assert dispatch.
{
    no warnings 'redefine';
    my @calls;
    local *Test2::Harness2::PreloadService::request_handler_spawn_service = sub {
        my (undef, $payload, $msg) = @_;
        push @calls, [$payload, $msg];
        return;
    };

    package FakeMsg;
    sub new { bless { content => $_[1] }, 'FakeMsg' }
    sub content { $_[0]->{content} }
    package main;

    my $svc = bless {}, 'Test2::Harness2::PreloadService';
    my $msg = FakeMsg->new({kind => 'spawn_service', class => 'X', peer_name => 'Y', spawn_id => 1, notify_to => 'harness'});
    $svc->run_on_general_message($msg);

    is(scalar(@calls), 1, 'dispatch routed one spawn_service message');
    is($calls[0]->[0]->{class}, 'X', 'payload carried through');
}

done_testing;

use Test2::V0;
use Test2::Harness2::Spawn;

# Verify the public broadcast_message wrapper on Spawn:
# - returns 1 on enqueue success and passes the payload through to
#   the underlying client's send_message
# - returns 0 on send failure, leaving the error in $@

{
    package FakeClient::OK;
    sub send_message {
        my ($self, $peer, $payload) = @_;
        $self->{last} = [$peer, $payload];
        return 1;
    }
}

{
    package FakeClient::Fail;
    sub send_message { die "boom\n" }
}

{
    package FakeHandle;
    sub new    { my ($class, $client) = @_; bless { client => $client }, $class }
    sub client { $_[0]->{client} }
}

sub make_spawn {
    my ($client) = @_;
    # Bare-bones bless: we skip ->new() so we don't need a real
    # pid/ipcm_info/workdir. Set _creator_pid so DESTROY's guard
    # short-circuits without warning.
    my $spawn = bless { _creator_pid => $$ }, 'Test2::Harness2::Spawn';
    $spawn->{Test2::Harness2::Spawn::HANDLE()}               = FakeHandle->new($client);
    $spawn->{Test2::Harness2::Spawn::TERMINATE_ON_DESTROY()} = 0;
    return $spawn;
}

subtest success => sub {
    my $client = bless { last => undef }, 'FakeClient::OK';
    my $spawn  = make_spawn($client);

    my $ok = $spawn->broadcast_message('peer-x', {request => 'reload'});
    is($ok, 1, 'success returns 1');
    is(
        $client->{last},
        ['peer-x', {request => 'reload'}],
        'payload reached client unchanged',
    );
};

subtest failure => sub {
    my $bad   = bless {}, 'FakeClient::Fail';
    my $spawn = make_spawn($bad);

    my $ok = $spawn->broadcast_message('peer-y', {request => 'reload'});
    is($ok,  0,         'failure returns 0');
    like($@, qr/boom/, '$@ contains the underlying error');
};

done_testing;

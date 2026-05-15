use Test2::V0;
use Test2::Harness2::Spawn;

my @calls;
my $stub_handle = bless { calls => \@calls }, 'StubHandle';
sub StubHandle::sync_request {
    my ($self, $peer, $payload) = @_;
    push @{$self->{calls}}, [ $peer, $payload ];
    return { response => { ok => 1, spawn_id => 1, mode => 'preload' } };
}

my $spawn = bless {
    Test2::Harness2::Spawn::NAME() => 'harness',
    handle => $stub_handle,
}, 'Test2::Harness2::Spawn';
no warnings 'redefine';
local *Test2::Harness2::Spawn::handle = sub { $stub_handle };

my $resp = $spawn->spawn_script({
    stage      => 'BASE',
    script_abs => '/tmp/x.pl',
    argv       => ['a'],
    env        => { HOME => '/h' },
    cwd        => '/tmp',
    sock_path  => '/tmp/x.sock',
    notify_to  => 'cli-1',
});

is($resp->{ok}, 1, 'ok forwarded');
is($resp->{spawn_id}, 1, 'spawn_id forwarded');
is(scalar(@calls), 1, 'one sync_request');
is($calls[0][0], 'harness', 'sent to harness peer');
is($calls[0][1]{request}, 'spawn_script', 'request key set');
is($calls[0][1]{stage},   'BASE',          'stage forwarded');
is($calls[0][1]{sock_path}, '/tmp/x.sock', 'sock_path forwarded');

done_testing;

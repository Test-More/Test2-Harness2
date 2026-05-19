use Test2::V0;
use File::Temp qw/tempdir/;
use IO::Socket::UNIX;
use App::Yath2::Spawn::Client;

subtest '_allocate_socket_path lives under given dir and is unique' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $p1 = App::Yath2::Spawn::Client::_allocate_socket_path($tmp);
    my $p2 = App::Yath2::Spawn::Client::_allocate_socket_path($tmp);
    like($p1, qr{\A\Q$tmp\E/.*\.sock\z}, 'under tmpdir');
    isnt($p1, $p2, 'distinct');
    ok(!-e $p1, 'does not exist yet');
};

subtest 'open_listener creates a SOCK_STREAM listener at the requested path' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $path = App::Yath2::Spawn::Client::_allocate_socket_path($tmp);
    my $listener = App::Yath2::Spawn::Client::_open_listener($path);
    isa_ok($listener, 'IO::Socket::UNIX');
    ok(-S $path, 'socket file exists');
    close $listener;
};

done_testing;

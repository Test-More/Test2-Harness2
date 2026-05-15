use Test2::V0;
use IO::Socket::UNIX;
use POSIX ();
use App::Yath2::Spawn::FdPass qw/send_fds recv_fds/;

subtest 'round-trip a single FD via socketpair' => sub {
    my ($sa, $sb) = IO::Socket::UNIX->socketpair(
        IO::Socket::UNIX::AF_UNIX(),
        IO::Socket::UNIX::SOCK_STREAM(),
        IO::Socket::UNIX::PF_UNSPEC(),
    ) or die "socketpair: $!";

    pipe(my $pr, my $pw) or die "pipe: $!";
    print $pw "hello-from-pipe\n";
    close $pw;

    send_fds($sa, [ fileno($pr) ]);

    my $fds = recv_fds($sb, 1);
    is(ref($fds), 'ARRAY', 'returns arrayref');
    is(scalar(@$fds), 1, 'one fd');

    open(my $got, '<&=', $fds->[0]) or die "fdopen: $!";
    my $line = <$got>;
    is($line, "hello-from-pipe\n", 'received FD reads same bytes');
};

subtest 'round-trip three FDs (stdin/stdout/stderr shape)' => sub {
    my ($sa, $sb) = IO::Socket::UNIX->socketpair(
        IO::Socket::UNIX::AF_UNIX(),
        IO::Socket::UNIX::SOCK_STREAM(),
        IO::Socket::UNIX::PF_UNSPEC(),
    ) or die "socketpair: $!";

    pipe(my $p1r, my $p1w) or die "pipe1: $!";
    pipe(my $p2r, my $p2w) or die "pipe2: $!";
    pipe(my $p3r, my $p3w) or die "pipe3: $!";
    print $p1w "ONE"; print $p2w "TWO"; print $p3w "THREE";
    close $_ for $p1w, $p2w, $p3w;

    send_fds($sa, [ fileno($p1r), fileno($p2r), fileno($p3r) ]);

    my $fds = recv_fds($sb, 3);
    is(scalar(@$fds), 3, 'three fds');

    my @got;
    for my $fd (@$fds) {
        open(my $fh, '<&=', $fd) or die "fdopen: $!";
        push @got, scalar(<$fh>);
    }
    is(\@got, ['ONE', 'TWO', 'THREE'], 'all three round-tripped in order');
};

subtest 'recv_fds throws when peer closes without sending' => sub {
    my ($sa, $sb) = IO::Socket::UNIX->socketpair(
        IO::Socket::UNIX::AF_UNIX(),
        IO::Socket::UNIX::SOCK_STREAM(),
        IO::Socket::UNIX::PF_UNSPEC(),
    ) or die "socketpair: $!";
    close $sa;
    like(
        dies { recv_fds($sb, 1) },
        qr/recvmsg|closed|no fds/i,
        'clear error when sender disconnected',
    );
};

done_testing;

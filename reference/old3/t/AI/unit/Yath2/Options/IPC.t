use Test2::V0;
use File::Spec();

# 1. The module loads cleanly.
ok(eval { require App::Yath2::Options::IPC; 1 }, 'App::Yath2::Options::IPC loads cleanly') or diag $@;

# 2. Source-level option presence/absence audit.
my $path = $INC{'App/Yath2/Options/IPC.pm'};
ok(-f $path, 'located source file');

open(my $fh, '<', $path) or die "open $path: $!";
local $/;
my $src = <$fh>;
close $fh;

my @kept = qw/ipc-dir ipc-dir-order ipc-protocol ipc-file/;
for my $name (@kept) {
    like($src, qr/\bname\s*=>\s*'\Q$name\E'/, "kept option present: $name");
}

my @dropped = qw/ipc-port ipc-peer-pid ipc-address ipc-prefix ipc-allow-multiple/;
for my $name (@dropped) {
    unlike(
        $src,
        qr/\bname\s*=>\s*'\Q$name\E'/,
        "dropped option absent: $name",
    );
}

# 3. Protocol normaliser behaviour.
is(
    App::Yath2::Options::IPC::_normalize_protocol('AtomicPipe'),
    'IPC::Manager::Client::AtomicPipe',
    'short name -> fully qualified',
);
is(
    App::Yath2::Options::IPC::_normalize_protocol('+Custom::Driver'),
    'Custom::Driver',
    '+ prefix forces a verbatim namespace',
);
is(
    App::Yath2::Options::IPC::_normalize_protocol('IPC::Manager::Client::UnixSocket'),
    'IPC::Manager::Client::UnixSocket',
    'fully qualified is left alone',
);

done_testing;

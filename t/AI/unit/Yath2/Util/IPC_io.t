use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();
use Fcntl qw/:mode/;

use App::Yath2::Util::IPC qw/write_ipc_file read_ipc_file unlink_ipc_file/;

my $dir  = tempdir(CLEANUP => 1);
my $path = File::Spec->catfile($dir, '.yath-nonce-h-1-aabbccdd');

my %payload = (
    yath_version => '2.000011',
    type         => 'nonce',
    hostname     => 'h',
    user         => 'u',
    pid          => 1,
    uuid         => 'aabbccdd',
    created_at   => 1714000000,
    workdir      => '/tmp/yath-aabbccdd',
    project      => '/tmp/proj',
    ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/tmp/yath-aabbccdd/ipc.fifo"]',
);

# write
write_ipc_file($path, \%payload);
ok(-f $path, 'file exists after write');

my $mode = (stat $path)[2] & 07777;
is(sprintf('%04o', $mode), '0600', 'permissions are 0600');

ok(!-e "${path}.pend", 'no leftover .pend');

# read round-trip
my $got = read_ipc_file($path);
is($got, \%payload, 'read returns identical payload');

# unlink with matching pid
unlink_ipc_file($path, $$);
ok(!-e $path, 'unlink with matching pid removed file');

# unlink missing-file is a no-op
ok(lives { unlink_ipc_file($path, $$) }, 'unlink missing file is a no-op');

# unlink with non-matching pid leaves file alone.
write_ipc_file($path, \%payload);
my $other_pid = $$ + 100_000;
unlink_ipc_file($path, $other_pid);
ok(-e $path, 'unlink with mismatched pid does NOT remove file');
unlink $path;

done_testing;

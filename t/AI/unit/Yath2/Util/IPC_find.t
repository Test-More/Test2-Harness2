use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();
use Sys::Hostname qw/hostname/;

use App::Yath2::Util::IPC qw/write_ipc_file find_ipc_files/;

my $dir  = tempdir(CLEANUP => 1);
my $host = hostname();

# Write three files: two on local host, one on a foreign host.
my @records = (
    {
        yath_version => '2.000011', type => 'nonce',     hostname => $host,    user => 'u',
        pid          => $$,         uuid => 'aaaaaaaa', created_at => 1000,
        workdir      => '/x', project => '/y',
        ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/p1"]',
    },
    {
        yath_version => '2.000011', type => 'persistent', hostname => $host,   user => 'u',
        pid          => $$,         uuid => 'bbbbbbbb',   created_at => 2000,
        workdir      => '/x', project => '/y',
        ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/p2"]',
    },
    {
        yath_version => '2.000011', type => 'nonce', hostname => 'other-host', user => 'u',
        pid          => 999_999_998, uuid => 'cccccccc', created_at => 3000,
        workdir      => '/x', project => '/y',
        ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/p3"]',
    },
);

for my $r (@records) {
    my $name = ".yath-$r->{type}-$r->{hostname}-$r->{pid}-$r->{uuid}";
    write_ipc_file(File::Spec->catfile($dir, $name), $r);
}

# Default filter (live + local host) drops the foreign-host entry only
# if 'host' is set; with default behaviour, local host is implied.
my $list = find_ipc_files(dirs => [$dir]);
is(scalar @$list, 2, 'default filter drops cross-host entry');
is($list->[0]{uuid}, 'bbbbbbbb', 'sorted newest first');

# type filter
$list = find_ipc_files(dirs => [$dir], type => 'persistent');
is(scalar @$list, 1, 'type filter keeps only persistent');
is($list->[0]{uuid}, 'bbbbbbbb');

# host => undef disables host filter, includes cross-host
$list = find_ipc_files(dirs => [$dir], host => undef);
is(scalar @$list, 3, 'host => undef returns all');

# Dead pid local entry should be dropped + unlinked
my $dead = {
    yath_version => '2.000011', type => 'nonce', hostname => $host, user => 'u',
    pid          => 999_999_999, uuid => 'deaddead', created_at => 500,
    workdir      => '/x', project => '/y',
    ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/p4"]',
};
my $dead_name = ".yath-nonce-$host-$dead->{pid}-deaddead";
my $dead_path = File::Spec->catfile($dir, $dead_name);
write_ipc_file($dead_path, $dead);

$list = find_ipc_files(dirs => [$dir]);
ok(!grep({ $_->{uuid} eq 'deaddead' } @$list), 'dead-pid local entry filtered');
ok(!-e $dead_path, 'dead-pid local entry unlinked');

done_testing;

use Test2::V0;

use File::Temp qw/tempdir/;

use App::Yath2::Log;

# auto => $path picks the backend by inspecting the filesystem
# entry: directory -> Log::Directory; tar.zidx file -> Log::TarZIdx;
# sqlite file -> Log::Sqlite; missing -> croak.

subtest 'auto with directory delegates to Directory backend' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = App::Yath2::Log->new(auto => $dir);
    isa_ok($log, ['App::Yath2::Log::Directory'], 'Directory backend');
};

subtest 'auto with missing path croaks' => sub {
    like(
        dies { App::Yath2::Log->new(auto => '/no/such/path-1234567890') },
        qr/does not exist/,
        'helpful error',
    );
};

subtest 'auto rejects empty string' => sub {
    like(
        dies { App::Yath2::Log->new(auto => '') },
        qr/auto/,
        'rejects empty string',
    );
};

subtest 'auto is mutually exclusive with file/dir/dbh/dsn/live' => sub {
    my $dir = tempdir(CLEANUP => 1);
    like(
        dies { App::Yath2::Log->new(auto => $dir, dir => $dir) },
        qr/mutually exclusive/,
        'auto + dir rejected',
    );
};

done_testing;

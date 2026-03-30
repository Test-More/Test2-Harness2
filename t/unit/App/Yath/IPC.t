use Test2::V0 -target => 'App::Yath::IPC';
use File::Spec;
use File::Temp qw/tempdir/;

subtest 'dir() does not warn when ENV USER is unset' => sub {
    my $tmp = tempdir(CLEANUP => 1);

    # Build minimal mock settings for the dir() method
    my $ipc_group = mock {} => (
        add => [dir => sub { undef }],
    );
    my $yath_group = mock {} => (
        add => [
            base_dir => sub { $tmp },
            orig_tmp => sub { $tmp },
        ],
    );
    my $settings = mock {} => (
        add => [
            ipc  => sub { $ipc_group },
            yath => sub { $yath_group },
        ],
    );

    my $ipc = $CLASS->new(settings => $settings);

    # Delete USER and LOGNAME to simulate CI environment
    local $ENV{USER};
    delete $ENV{USER};
    local $ENV{LOGNAME};
    delete $ENV{LOGNAME};

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $dir = $ipc->dir;

    is(\@warnings, [], 'no warnings when $ENV{USER} is not set');
    ok(defined $dir, 'dir() returns a defined value');
    like($dir, qr/yath-ipc-/, 'dir contains expected prefix');
};

done_testing;

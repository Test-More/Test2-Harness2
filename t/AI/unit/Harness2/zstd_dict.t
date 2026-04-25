use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use FindBin ();
use File::Spec ();

use Test2::Harness2;

my $repo_dict = File::Spec->catfile(
    $FindBin::Bin, '..', '..', '..', '..', 'share', 'other', 'zstd.dict',
);

unless (-f $repo_dict) {
    plan skip_all => "share/other/zstd.dict not found at $repo_dict";
}

subtest 'explicit dict_path is copied into logdir' => sub {
    my $wd = tempdir(CLEANUP => 1);
    my $h  = Test2::Harness2->new(
        workdir    => $wd,
        ipc_parent => 1,
        dict_path  => $repo_dict,
    );

    my $logdir_dict = "$wd/logs/zstd-dict.bin";
    ok(-f $logdir_dict, "zstd-dict.bin landed in logdir");
    is(-s $logdir_dict, -s $repo_dict, "size matches source");

    is($h->dict_path, $repo_dict, "harness records its dict_path");
};

subtest 'dict_path => undef leaves no dict in logdir' => sub {
    my $wd = tempdir(CLEANUP => 1);
    my $h  = Test2::Harness2->new(
        workdir    => $wd,
        ipc_parent => 1,
        dict_path  => undef,
    );

    ok(!-e "$wd/logs/zstd-dict.bin", "no dict written for explicit dict-less run");
    is($h->dict_path, undef, "dict_path is undef");
};

subtest 'unreadable dict_path croaks at init' => sub {
    my $wd = tempdir(CLEANUP => 1);
    like(
        dies {
            Test2::Harness2->new(
                workdir    => $wd,
                ipc_parent => 1,
                dict_path  => '/no/such/dict/file.bin',
            );
        },
        qr/dict_path .* does not exist/,
        "explicit path that does not exist is an error",
    );
};

done_testing;

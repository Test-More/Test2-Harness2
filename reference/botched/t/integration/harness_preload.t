use strict;
use warnings;
use Test2::V0;
use File::Spec;

BEGIN {
    my $ipcm_lib = '/home/exodist/projects/IPC-Manager/lib';
    if (-d $ipcm_lib) {
        unshift @INC, $ipcm_lib;
    }
    else {
        plan skip_all => "IPC::Manager lib not found at $ipcm_lib";
    }

    my $ok  = eval { require IPC::Manager; 1 };
    my $err = $@;
    plan skip_all => "IPC::Manager not loadable: $err" unless $ok;
}

use Test2::Harness2;
use Test2::Harness2::TestFile;

subtest 'harness with preloads' => sub {
    my @files = map { Test2::Harness2::TestFile->new(file => File::Spec->rel2abs($_)); } ('t/selftest/simple.t', 't/selftest/tap_only.t');

    my $harness = Test2::Harness2->new(
        job_count => 2,
        includes  => ['lib'],
        preloads  => ['Scalar::Util', 'List::Util'],
    );

    my $result = $harness->run_tests(test_files => \@files);
    ok($result->{passed}, "all tests passed with preloads");
    is($result->{total},  2, "2 tests ran");
    is($result->{failed}, 0, "0 failures");
};

subtest 'harness without preloads still works' => sub {
    my @files = (
        Test2::Harness2::TestFile->new(file => File::Spec->rel2abs('t/selftest/simple.t')),
    );

    my $harness = Test2::Harness2->new(
        job_count => 1,
        includes  => ['lib'],
    );

    my $result = $harness->run_tests(test_files => \@files);
    ok($result->{passed}, "works without preloads");
};

done_testing;

use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use FindBin ();
use File::Spec ();

use Test2::Harness2::Util::File::JSON::Zstd;

my $repo_dict = File::Spec->catfile(
    $FindBin::Bin, '..', '..', '..', '..', '..', 'share', 'other', 'zstd.dict',
);

my $tmp = tempdir(CLEANUP => 1);

subtest 'write/read round-trip (no dict)' => sub {
    my $path = "$tmp/snap_nodict.json.zst";
    my $f = Test2::Harness2::Util::File::JSON::Zstd->new(name => $path);

    my $data = { run_id => 'abc', pending => [1, 2, 3], done => {} };
    $f->write($data);
    ok(-f $path, "file exists");

    my $f2 = Test2::Harness2::Util::File::JSON::Zstd->new(name => $path);
    is($f2->read, $data, "round-trip");
};

subtest 'write/read round-trip (with dict)' => sub {
    plan skip_all => "dict not present" unless -f $repo_dict;

    my $path = "$tmp/snap_dict.json.zst";
    my $f = Test2::Harness2::Util::File::JSON::Zstd->new(
        name      => $path,
        dict_path => $repo_dict,
    );

    my $data = { run_id => 'abc', kind => 'run_mutation' };
    $f->write($data);

    my $f2 = Test2::Harness2::Util::File::JSON::Zstd->new(
        name      => $path,
        dict_path => $repo_dict,
    );
    is($f2->read, $data, "dict round-trip");

    # Wrong dict (no dict) should fail to decode.
    my $f3 = Test2::Harness2::Util::File::JSON::Zstd->new(name => $path);
    like(
        dies { $f3->read },
        qr/decompress/i,
        "no-dict reader fails on dict-encoded content",
    );
};

subtest 'maybe_read returns undef for missing file' => sub {
    my $f = Test2::Harness2::Util::File::JSON::Zstd->new(
        name => "$tmp/does_not_exist.json.zst",
    );
    is($f->maybe_read, undef, "missing file -> undef");
};

done_testing;

use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use FindBin ();
use File::Spec ();

use Test2::Harness2::Util::File::JSONL::Zstd;

my $repo_dict = File::Spec->catfile(
    $FindBin::Bin, '..', '..', '..', '..', '..', 'share', 'other', 'zstd.dict',
);

my $tmp = tempdir(CLEANUP => 1);

subtest 'write/read round-trip (no dict)' => sub {
    my $path = "$tmp/events_nodict.jsonl.zst";
    my $f    = Test2::Harness2::Util::File::JSONL::Zstd->new(name => $path);

    $f->write({i => 1, k => 'a'}, {i => 2, k => 'b'}, {i => 3, k => 'c'});

    my $r = Test2::Harness2::Util::File::JSONL::Zstd->new(name => $path);
    my @items = $r->poll;
    is(\@items, [{i => 1, k => 'a'}, {i => 2, k => 'b'}, {i => 3, k => 'c'}], 'all entries decoded');
};

subtest 'write/read round-trip (with dict)' => sub {
    plan skip_all => "dict not present" unless -f $repo_dict;

    my $path = "$tmp/events_dict.jsonl.zst";

    my $f = Test2::Harness2::Util::File::JSONL::Zstd->new(
        name      => $path,
        dict_path => $repo_dict,
    );
    $f->write({event => $_, kind => 'sample'}) for 1 .. 10;

    my $r = Test2::Harness2::Util::File::JSONL::Zstd->new(
        name      => $path,
        dict_path => $repo_dict,
    );
    my @items = $r->poll;
    is(scalar @items, 10, 'all 10 frames decoded');
    is($items[0], {event => 1, kind => 'sample'}, 'first');
    is($items[9], {event => 10, kind => 'sample'}, 'last');
};

subtest 'append between polls (tail behavior)' => sub {
    my $path = "$tmp/tail.jsonl.zst";

    my $f = Test2::Harness2::Util::File::JSONL::Zstd->new(name => $path);
    $f->write({i => 1});

    my $r = Test2::Harness2::Util::File::JSONL::Zstd->new(name => $path);
    my @first = $r->poll;
    is(\@first, [{i => 1}], 'first poll returns first frame');

    $f->write({i => 2}, {i => 3});

    my @second = $r->poll;
    is(\@second, [{i => 2}, {i => 3}], 'second poll returns appended frames');
};

subtest 'peek does not advance position' => sub {
    my $path = "$tmp/peek.jsonl.zst";

    my $f = Test2::Harness2::Util::File::JSONL::Zstd->new(name => $path);
    $f->write({a => 1}, {a => 2});

    my $r = Test2::Harness2::Util::File::JSONL::Zstd->new(name => $path);
    my @peek = $r->poll_with_index(max => 1, peek => 1);
    is(scalar @peek, 1, 'peek returned one row');

    my @full = $r->poll;
    is(scalar @full, 2, 'subsequent poll still sees both rows');
};

done_testing;

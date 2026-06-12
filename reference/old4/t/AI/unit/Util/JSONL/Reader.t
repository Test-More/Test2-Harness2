use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::JSONL::Reader;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

subtest bytes_mode => sub {
    my $r = Test2::Harness2::Util::JSONL::Reader->new(bytes => qq[{"a":1}\n{"b":2}\n]);
    is([$r->read_lines], [{a => 1}, {b => 2}]);
};

subtest bytes_zstd_mode => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x.jsonl.zst";
    my $w = open_zstd_writer($f);
    $w->say(qq[{"k":1}]);
    $w->say(qq[{"k":2}]);
    $w->close;

    open(my $fh, '<', $f) or die $!;
    binmode $fh;
    local $/;
    my $bytes = <$fh>;
    close $fh;

    my $r = Test2::Harness2::Util::JSONL::Reader->new(bytes_zstd => $bytes);
    is([$r->read_lines], [{k => 1}, {k => 2}]);
};

subtest path_plain => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x.jsonl";
    open(my $fh, '>', $f) or die $!;
    print $fh qq[{"a":1}\n{"a":2}\n];
    close $fh;

    my $r = Test2::Harness2::Util::JSONL::Reader->new(path => $f);
    is([$r->read_lines], [{a => 1}, {a => 2}]);
    is([$r->read_lines], [], 'no more');
};

subtest path_zst_tail => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x.jsonl.zst";

    my $w = open_zstd_writer($f);
    $w->say(qq[{"a":1}]);

    my $r = Test2::Harness2::Util::JSONL::Reader->new(path => $f);
    is([$r->read_lines], [{a => 1}]);
    is([$r->read_lines], []);

    $w->say(qq[{"a":2}]);
    is([$r->read_lines], [{a => 2}]);
};

subtest torn_line => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x.jsonl";
    open(my $fh, '>', $f) or die $!;
    print $fh qq[{"a":1}\n], '{"b":2';
    close $fh;

    my $r = Test2::Harness2::Util::JSONL::Reader->new(path => $f);
    is([$r->read_lines], [{a => 1}], 'torn final line held back');

    open(my $fh2, '>>', $f) or die $!;
    print $fh2 qq[}\n];
    close $fh2;
    is([$r->read_lines], [{b => 2}], 'completes once writer finishes');
};

subtest exists => sub {
    my $r = Test2::Harness2::Util::JSONL::Reader->new(bytes => qq[]);
    ok($r->exists, 'in-memory reader exists');
    my $r2 = Test2::Harness2::Util::JSONL::Reader->new(path => '/no/such/file/xx');
    ok(!$r2->exists, 'missing path does not exist');
};

done_testing;

use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::Zstd qw{
    compress_blob
    decompress_blob
    open_zstd_writer
    open_zstd_reader
    open_zstd_reader_fh
    compress_file_atomic
    decompress_file
    zstd_frame_size
    ZSTD_FRAME_MAGIC
};

subtest blob_round_trip => sub {
    my $bytes = "hello world\nthis has multiple lines\n";
    my $z     = compress_blob($bytes);
    is(decompress_blob($z), $bytes);
};

subtest frame_size => sub {
    my $z   = compress_blob("payload");
    my $sz  = zstd_frame_size($z);
    is($sz, length($z), 'frame size matches full frame');
    is(zstd_frame_size("not zstd"), undef);
    is(zstd_frame_size(""),         undef);
    is(zstd_frame_size(substr($z, 0, 5)), undef, 'incomplete frame returns undef');
};

subtest file_atomic_round_trip => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x.zst";
    compress_file_atomic($f, "ABC");
    is(decompress_file($f), "ABC");
};

subtest writer_reader_round_trip => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/events.jsonl.zst";

    my $w = open_zstd_writer($f);
    $w->print(qq[{"a":1}\n]);
    $w->say(qq[{"b":2}]);
    $w->close;

    my $r = open_zstd_reader($f);
    my @lines;
    while (defined(my $line = $r->readline)) {
        push @lines => $line;
    }
    is(\@lines, [qq[{"a":1}\n], qq[{"b":2}\n]]);
};

subtest reader_tail => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/tail.zst";

    my $w = open_zstd_writer($f);
    $w->print("one\n");

    my $r = open_zstd_reader($f);
    is($r->readline, "one\n");
    is($r->readline, undef, 'no more for now');

    $w->print("two\n");
    is($r->readline, "two\n", 'sees new frame after writer appends');
};

subtest reader_fh => sub {
    my $z = compress_blob("scalar-fh") . compress_blob("second");
    open(my $sfh, '<', \$z) or die "scalar fh: $!";
    my $r = open_zstd_reader_fh($sfh);
    is($r->readline, "scalar-fh");
    is($r->readline, "second");
    is($r->readline, undef);
};

subtest constants => sub {
    is(ZSTD_FRAME_MAGIC, "\x28\xB5\x2F\xFD");
};

done_testing;

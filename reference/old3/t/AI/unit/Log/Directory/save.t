use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use App::Yath2::Log;
use Test2::Harness2::Util::Zstd qw/decompress_blob/;

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services/harness");
make_path("$dir/runs/0/jobs/0/0");

# Sealed dir: compress=off by default.
my $log = App::Yath2::Log->new(dir => $dir);

# save at archive root.
{
    my $a = $log->artifacts();
    my $path = $a->save('meta.json', '{"foo":1}');
    ok(-e $path, 'meta.json written at root');
    is($path, "$dir/meta.json", 'returned absolute path');

    # Default compress=off for sealed dir means no .zst extension was added.
    ok(!-e "$dir/meta.json.zst", 'no .zst suffix for sealed dir default');

    open(my $fh, '<', $path) or die $!;
    binmode $fh;
    my $bytes = do { local $/; <$fh> };
    close $fh;
    is($bytes, '{"foo":1}', 'plain content');

    # Read back via get().
    is($a->get('meta.json'), '{"foo":1}', 'get reads back');
    ok($a->exists('meta.json'), 'exists');
}

# save with compress=>1: file gets .zst suffix.
{
    my $a = $log->artifacts(0, 0);
    my $path = $a->save('extra.txt', "hello\n", compress => 1);
    is($path, "$dir/runs/0/jobs/0/0/extra.txt.zst", 'compressed save adds .zst');

    open(my $fh, '<', $path) or die $!;
    binmode $fh;
    my $bytes = do { local $/; <$fh> };
    close $fh;

    is(decompress_blob($bytes), "hello\n", 'compressed bytes decompress');

    # get() should return decompressed by default.
    is($a->get('extra.txt'), "hello\n", 'get returns decompressed');

    # exists() should match either form.
    ok($a->exists('extra.txt'), 'exists matches .zst form');
}

# Live dir: compress on by default.
{
    my $live_dir = tempdir(CLEANUP => 1);
    make_path("$live_dir/services/harness");
    my $live = App::Yath2::Log->new(live => $live_dir);
    my $a = $live->artifacts();
    my $path = $a->save('meta.json', '{"x":1}');
    is($path, "$live_dir/meta.json.zst", 'live dir saves compressed');
}

# force_no_overwrite throws on existing.
{
    my $a = $log->artifacts(0, 0);
    $a->save('exists.txt', 'one');
    like(
        dies { $a->save('exists.txt', 'two', force_no_overwrite => 1) },
        qr/already exists/,
        'force_no_overwrite throws',
    );
    # Without the flag, overwrite is fine.
    my $ok = eval { $a->save('exists.txt', 'two'); 1 };
    ok($ok, 'overwrite ok without force_no_overwrite');
    is($a->get('exists.txt'), 'two', 'overwritten content');
}

# Path traversal blocked.
{
    my $a = $log->artifacts();
    like(
        dies { $a->save('../escaped.txt', 'no') },
        qr/must not contain/,
        'path traversal blocked',
    );
}

done_testing;

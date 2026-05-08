use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::JSON  qw/encode_json/;
use Test2::Harness2::Util::Zstd  qw/open_zstd_writer/;
use App::Yath2::Log::Iterator::JSONL;

# Plain (non-zstd) jsonl file: next/first/last/count.
{
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/plain.jsonl";
    open(my $fh, '>', $path) or die $!;
    print $fh qq[{"row":1}\n];
    print $fh qq[{"row":2}\n];
    print $fh qq[{"row":3}\n];
    close $fh;

    my $it = App::Yath2::Log::Iterator::JSONL->new(path => $path);
    is($it->count, 3, 'plain: count');
    is($it->first->{row}, 1, 'plain: first');
    is($it->last->{row},  3, 'plain: last');
}

# Zstd jsonl file: same as above.
{
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/multi.jsonl.zst";
    my $w = open_zstd_writer($path);
    $w->say(encode_json({row => $_})) for 1 .. 5;
    $w->close;

    my $it = App::Yath2::Log::Iterator::JSONL->new(path => $path);
    is($it->count, 5, 'zstd: count');
    is($it->first->{row}, 1, 'zstd: first');
    is($it->last->{row},  5, 'zstd: last');

    $it->reset;
    my @rows;
    while (defined(my $r = $it->next(0))) {
        push @rows => $r->{row};
    }
    is(\@rows, [1, 2, 3, 4, 5], 'zstd: full drain after reset');
}

# Sealed EOE flips true after drain.
{
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/seal.jsonl";
    open(my $fh, '>', $path) or die $!;
    print $fh qq[{"x":1}\n];
    close $fh;

    my $it = App::Yath2::Log::Iterator::JSONL->new(path => $path);
    is($it->EOE, 0, 'EOE false at start');
    my $r = $it->next(0);
    is($r->{x}, 1, 'got the row');
    is($it->next(0), undef, 'no more rows');
    is($it->EOE, 1, 'EOE flips true after drain');
}

done_testing;

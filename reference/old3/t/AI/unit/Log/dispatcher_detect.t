use Test2::V0;
use File::Temp qw/tempdir/;

use App::Yath2::Log;
use App::Yath2::Log::Footer qw/pack_footer FORMAT_ID_TAR FORMAT_ID_SQL/;

my $tmp = tempdir(CLEANUP => 1);

# detect_file_kind: SQLite magic.
{
    my $path = "$tmp/sqlite.bin";
    open(my $fh, '>', $path) or die $!;
    binmode $fh;
    print $fh "SQLite format 3\0";
    close $fh;
    is(App::Yath2::Log->detect_file_kind($path), 'sqlite', 'detects sqlite magic');
}

# detect_file_kind: YATHFOOT trailer with format_id=TAR.
{
    my $path = "$tmp/tarzidx.bin";
    open(my $fh, '>', $path) or die $!;
    binmode $fh;
    print $fh "garbage" x 100;
    print $fh pack_footer(
        format_id   => FORMAT_ID_TAR,
        meta_offset => 0,
        meta_size   => 0,
        body_size   => 0,
    );
    close $fh;
    is(App::Yath2::Log->detect_file_kind($path), 'tar.zidx', 'detects YATHFOOT TAR trailer');
}

# detect_file_kind: YATHFOOT trailer with format_id=SQL on a non-sqlite-header file.
{
    my $path = "$tmp/sqlfoot.bin";
    open(my $fh, '>', $path) or die $!;
    binmode $fh;
    print $fh "not the sqlite header" x 10;
    print $fh pack_footer(
        format_id   => FORMAT_ID_SQL,
        meta_offset => 0,
        meta_size   => 0,
        body_size   => 0,
    );
    close $fh;
    is(App::Yath2::Log->detect_file_kind($path), 'sqlite', 'detects YATHFOOT SQL trailer');
}

# detect_file_kind: unknown.
{
    my $path = "$tmp/unknown.bin";
    open(my $fh, '>', $path) or die $!;
    binmode $fh;
    print $fh "no magic of any kind here";
    close $fh;
    is(App::Yath2::Log->detect_file_kind($path), 'unknown', 'unknown bytes');
}

done_testing;

use Test2::V0;
use File::Temp qw/tempdir tempfile/;

use App::Yath2::Log;

# _detect_file_kind: SQLite magic.
{
    my (undef, $path) = tempfile(OPEN => 0, UNLINK => 1);
    open(my $fh, '>', $path) or die $!;
    binmode $fh;
    print $fh "SQLite format 3\0";
    close $fh;
    is(App::Yath2::Log->_detect_file_kind($path), 'sqlite', 'detects sqlite magic');
}

# _detect_file_kind: tar.zidx footer.
{
    my (undef, $path) = tempfile(OPEN => 0, UNLINK => 1);
    open(my $fh, '>', $path) or die $!;
    binmode $fh;
    # Some random head bytes, then a 32-byte tail with the magic at offset 0.
    print $fh "garbage" x 100;
    print $fh "YZIDXv1\0", "\0" x 24;    # 32-byte footer; size irrelevant.
    close $fh;
    is(App::Yath2::Log->_detect_file_kind($path), 'tar.zidx', 'detects tar.zidx footer');
}

# _detect_file_kind: unknown.
{
    my (undef, $path) = tempfile(OPEN => 0, UNLINK => 1);
    open(my $fh, '>', $path) or die $!;
    binmode $fh;
    print $fh "no magic of any kind here";
    close $fh;
    is(App::Yath2::Log->_detect_file_kind($path), 'unknown', 'unknown bytes');
}

done_testing;

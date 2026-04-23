use Test2::V0;
use File::Temp qw/tempdir tempfile/;
use App::Yath2::LogArchive::Format qw/detect_format/;

my $dir = tempdir(CLEANUP => 1);
is(detect_format($dir), 'directory', 'dir');

my %magics = (
    zip       => "PK\x03\x04" . ("\0" x 20),
    '7z'      => "7z\xBC\xAF\x27\x1C" . ("\0" x 20),
    'tar.gz'  => "\x1f\x8b\x08" . ("\0" x 20),
    'tar.bz2' => "BZh9" . ("\0" x 20),
);
for my $fmt (sort keys %magics) {
    my ($fh, $file) = tempfile(UNLINK => 1);
    binmode $fh;
    print $fh $magics{$fmt};
    close $fh;
    is(detect_format($file), $fmt, "magic -> $fmt");
}

# ustar detection: 257 bytes then 'ustar\0'
my ($fh, $file) = tempfile(UNLINK => 1);
binmode $fh;
print $fh ("\0" x 257), "ustar\0", ("\0" x 200);
close $fh;
is(detect_format($file), 'tar', 'ustar -> tar');

# Unknown
my ($fh2, $file2) = tempfile(UNLINK => 1);
binmode $fh2;
print $fh2 "GARBAGE" . ("\0" x 600);
close $fh2;
like(
    dies { detect_format($file2) },
    qr/LogArchive: unknown format for \Q$file2\E/,
    'unknown format croaks with path',
);

done_testing;

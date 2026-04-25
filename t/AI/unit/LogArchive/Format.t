use Test2::V0;
use File::Temp qw/tempdir tempfile/;
use App::Yath2::LogArchive::Format qw/
    detect_format
    default_writer_format
    DEFAULT_WRITER_PREFERENCE
    TAR_ZIDX_MAGIC
/;

my $dir = tempdir(CLEANUP => 1);
is(detect_format($dir), 'directory', 'directory');

# tar.zidx detection: a real tar.zidx archive places its 32-byte
# footer at end-of-file with TAR_ZIDX_MAGIC at byte 0. Stub a file
# with that shape so the detector sees the magic.
my ($fh, $file) = tempfile(UNLINK => 1);
binmode $fh;
my $padding = ("\0" x 64);
my $footer  = pack('a8 Q< Q< Q<', TAR_ZIDX_MAGIC, 0, 0, 0);
print $fh $padding, $footer;
close $fh;
is(detect_format($file), 'tar.zidx', 'magic-byte detection finds tar.zidx');

# Anything that is neither a directory nor tar.zidx croaks with
# the new "unknown archive format" message. The previous
# multi-format support (tar / tar.gz / tar.bz2 / zip / 7z) was
# removed -- detect_format does not look for their magics.
my ($fh2, $file2) = tempfile(UNLINK => 1);
binmode $fh2;
print $fh2 "PK\x03\x04" . ("\0" x 100);
close $fh2;
like(
    dies { detect_format($file2) },
    qr/unknown archive format/,
    'zip-magic file rejected (multi-format support removed)',
);

my ($fh3, $file3) = tempfile(UNLINK => 1);
binmode $fh3;
print $fh3 "GARBAGE" . ("\0" x 100);
close $fh3;
like(
    dies { detect_format($file3) },
    qr/unknown archive format/,
    'unknown bytes -> unknown archive format',
);

# default_writer_format always returns tar.zidx; the preference
# list collapses to a single entry.
is(default_writer_format(),       'tar.zidx',   'default_writer_format = tar.zidx');
is([DEFAULT_WRITER_PREFERENCE()], ['tar.zidx'], 'preference list collapses to tar.zidx');

done_testing;

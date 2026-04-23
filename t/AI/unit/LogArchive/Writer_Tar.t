use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use App::Yath2::LogArchive;

for my $fmt (qw/tar tar.gz tar.bz2/) {
    subtest $fmt => sub {
        my $src = tempdir(CLEANUP => 1);
        open my $fh, '>', "$src/one.txt" or die $!;
        print $fh "one\n";
        close $fh;

        my (undef, $out) = tempfile(OPEN => 0, SUFFIX => ".$fmt", UNLINK => 1);
        unlink $out;
        App::Yath2::LogArchive->create(source => $src, path => $out, format => $fmt);
        ok(-s $out, "$fmt output exists and non-empty");

        my $la = App::Yath2::LogArchive->new(path => $out);
        my @files = sort $la->list_files;
        is(\@files, ['one.txt'], "$fmt list_files");

        my $f = $la->read_file('one.txt');
        is(scalar(<$f>), "one\n", "$fmt read_file");
    };
}

done_testing;

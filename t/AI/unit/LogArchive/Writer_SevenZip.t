use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use App::Yath2::LogArchive;
use App::Yath2::LogArchive::Format qw/writer_class_for/;

my $writer = eval { writer_class_for('7z') };
skip_all 'no viable 7z writer' unless $writer;

my $src = tempdir(CLEANUP => 1);
open my $fh, '>', "$src/one.txt" or die $!;
print $fh "one\n";
close $fh;

my (undef, $out) = tempfile(OPEN => 0, SUFFIX => '.7z', UNLINK => 1);
unlink $out;
App::Yath2::LogArchive->create(source => $src, path => $out, format => '7z');
ok(-s $out, '7z output exists and non-empty');

my $la = App::Yath2::LogArchive->new(path => $out);
my @files = sort $la->list_files;
is(\@files, ['one.txt'], '7z list_files');

my $f = $la->read_file('one.txt');
is(scalar(<$f>), "one\n", '7z read_file');

done_testing;

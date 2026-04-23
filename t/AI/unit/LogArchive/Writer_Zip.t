use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use App::Yath2::LogArchive;
use App::Yath2::LogArchive::Format qw/writer_class_for/;

my $writer = eval { writer_class_for('zip') };
skip_all 'no viable zip writer' unless $writer;

my $src = tempdir(CLEANUP => 1);
open my $fh, '>', "$src/one.txt" or die $!;
print $fh "one\n";
close $fh;

my (undef, $out) = tempfile(OPEN => 0, SUFFIX => '.zip', UNLINK => 1);
unlink $out;
App::Yath2::LogArchive->create(source => $src, path => $out, format => 'zip');
ok(-s $out, "zip output exists and non-empty");

my $la = App::Yath2::LogArchive->new(path => $out);
my @files = sort $la->list_files;
is(\@files, ['one.txt'], 'zip list_files');

my $f = $la->read_file('one.txt');
is(scalar(<$f>), "one\n", 'zip read_file');

done_testing;

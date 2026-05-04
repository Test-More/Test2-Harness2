use Test2::V0;

use File::Temp qw/tempdir/;
use App::Yath2::Log::Directory;

my $dir = tempdir(CLEANUP => 1);
open my $fh, '>', "$dir/hello.txt" or die $!;
print $fh "hi\n";
close $fh;

my $d = App::Yath2::Log::Directory->new(path => $dir, format => 'directory');
ok($d->has_file('hello.txt'), 'has_file');
ok(!$d->has_file('no.txt'),   '!has_file');
is([$d->list_files], ['hello.txt'], 'list_files');
my $f = $d->read_file('hello.txt');
is(scalar(<$f>), "hi\n", 'read_file contents');

done_testing;

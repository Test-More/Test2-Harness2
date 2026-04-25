use Test2::V0;

use IPC::Cmd qw/can_run/;

use File::Temp qw/tempdir tempfile/;

sub _build_7z {
    my ($src, $out) = @_;
    my $bin = scalar can_run('7z') or return 0;
    my $pid = fork // die "fork: $!";
    unless ($pid) {
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec $bin, 'a', $out, "$src/.";
        die "exec: $!";
    }
    waitpid $pid, 0;
    return $? == 0;
}

my @CLASSES;
for my $class (qw/App::Yath2::LogArchive::SevenZip::External App::Yath2::LogArchive::SevenZip::PP/) {
    unless (eval "require $class; 1") {
        diag("skip $class: $@");
        next;
    }
    next unless $class->viable;
    push @CLASSES => $class;
}

plan skip_all => 'no viable 7z backend (install p7zip or Archive::SevenZip)'
    unless @CLASSES;

for my $class (@CLASSES) {
    subtest $class => sub {
        my $src = tempdir(CLEANUP => 1);
        open my $fh, '>', "$src/a.txt" or die $!;
        print $fh "A\n";
        close $fh;
        open $fh, '>', "$src/b.txt" or die $!;
        print $fh "BB\n";
        close $fh;

        my (undef, $out) = tempfile(OPEN => 0, SUFFIX => '.7z', UNLINK => 1);
        unlink $out;
        unless (_build_7z($src, $out)) {
            skip_all 'cannot build 7z fixture';
        }

        my $la = $class->new(path => $out, format => '7z');
        my @files = sort $la->list_files;
        is(\@files, [qw/a.txt b.txt/], "$class list_files");

        ok($la->has_file('a.txt'), 'has_file');
        my $rfh = $la->read_file('a.txt');
        is(scalar(<$rfh>), "A\n", 'read_file content');
    };
}

done_testing;

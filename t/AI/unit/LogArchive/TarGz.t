use Test2::V0;

use File::Temp qw/tempdir tempfile/;

for my $class (qw/App::Yath2::LogArchive::TarGz::External App::Yath2::LogArchive::TarGz::PP/) {
    unless (eval "require $class; 1") {
        diag("skip $class: $@");
        next;
    }
    next unless $class->viable;

    subtest $class => sub {
        my $src = tempdir(CLEANUP => 1);
        open my $fh, '>', "$src/a.txt" or die $!;
        print $fh "A\n";
        close $fh;
        open $fh, '>', "$src/b.txt" or die $!;
        print $fh "BB\n";
        close $fh;

        my (undef, $out) = tempfile(OPEN => 0, SUFFIX => '.tar.gz', UNLINK => 1);
        unless (system('tar', '-czf', $out, '-C', $src, '.') == 0) {
            skip_all 'cannot build tar.gz fixture';
        }

        my $la = $class->new(path => $out, format => 'tar.gz');
        my @files = sort $la->list_files;
        @files = grep { $_ ne '.' && $_ ne './' } @files;
        is(\@files, [qw/a.txt b.txt/], "$class list_files");

        ok($la->has_file('a.txt'), 'has_file');
        my $rfh = $la->read_file('a.txt');
        is(scalar(<$rfh>), "A\n", 'read_file content');
    };
}

done_testing;

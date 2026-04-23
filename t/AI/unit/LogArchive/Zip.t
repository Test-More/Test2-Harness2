use Test2::V0;

use IPC::Cmd qw/can_run/;

use File::Temp qw/tempdir tempfile/;

sub _build_zip {
    my ($src, $out) = @_;
    if (my $sevenz = scalar can_run('7z')) {
        my $pid = fork // die "fork: $!";
        unless ($pid) {
            open(STDOUT, '>', '/dev/null');
            open(STDERR, '>', '/dev/null');
            exec $sevenz, 'a', '-tzip', $out, "$src/.";
            die "exec: $!";
        }
        waitpid $pid, 0;
        return $? == 0;
    }
    if (my $zip = scalar can_run('zip')) {
        my $pid = fork // die "fork: $!";
        unless ($pid) {
            chdir $src or die "chdir: $!";
            exec $zip, '-r', $out, '.';
            die "exec: $!";
        }
        waitpid $pid, 0;
        return $? == 0;
    }
    return 0;
}

for my $class (qw/App::Yath2::LogArchive::Zip::External App::Yath2::LogArchive::Zip::PP/) {
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

        my (undef, $out) = tempfile(OPEN => 0, SUFFIX => '.zip', UNLINK => 1);
        unlink $out;
        unless (_build_zip($src, $out)) {
            skip_all 'cannot build zip fixture (need zip or 7z)';
        }

        my $la = $class->new(path => $out, format => 'zip');
        my @files = sort $la->list_files;
        is(\@files, [qw/a.txt b.txt/], "$class list_files");

        ok($la->has_file('a.txt'), 'has_file');
        my $rfh = $la->read_file('a.txt');
        is(scalar(<$rfh>), "A\n", 'read_file content');
    };
}

done_testing;

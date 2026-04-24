use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();
use Role::Tiny ();

use lib 't/lib';
use App::Yath2::Finder;

ok(
    Role::Tiny::does_role('App::Yath2::Finder', 'App::Yath2::Role::Finder'),
    'App::Yath2::Finder consumes App::Yath2::Role::Finder',
);

# Write a small test file into $dir/$relpath.
sub touch_file {
    my ($dir, $relpath) = @_;
    my $full = File::Spec->catfile($dir, $relpath);
    my @parts = File::Spec->splitdir($relpath);
    if (@parts > 1) {
        my $parent = File::Spec->catfile($dir, @parts[0 .. $#parts - 1]);
        make_path($parent) unless -d $parent;
    }
    open my $fh, '>', $full or die "touch $full: $!";
    print $fh "1;\n";
    close $fh;
    return $full;
}

# Extract bare relative paths from a find_files result arrayref.
sub found_relpaths {
    my ($files) = @_;
    return [sort map { $_->relative } @$files];
}

subtest 'basic discovery finds .t and .t2 files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    touch_file($dir, 'a.t');
    touch_file($dir, 'b.t2');
    touch_file($dir, 'skip.pl');

    my $finder = App::Yath2::Finder->new(search => [$dir]);
    my $files = $finder->find_files([]);

    is(scalar @$files, 2, 'found two files');
    my @exts = sort map { (my $e = $_->file) =~ s/.*\.//; $e } @$files;
    is(\@exts, [qw/t t2/], 'correct extensions');
};

subtest '--extensions restricts to custom suffixes' => sub {
    my $dir = tempdir(CLEANUP => 1);
    touch_file($dir, 'a.t');
    touch_file($dir, 'b.tx');
    touch_file($dir, 'c.txx');

    my $finder = App::Yath2::Finder->new(
        search     => [$dir],
        extensions => [qw/tx txx/],
    );
    my $files = $finder->find_files([]);

    is(scalar @$files, 2, 'found two custom-extension files');
    my @names = sort map { (my $n = $_->file) =~ s{.*/}{}; $n } @$files;
    is(\@names, [qw/b.tx c.txx/], 'correct filenames');
};

subtest '--exclude-file removes a named file' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $keep = touch_file($dir, 'keep.t');
    my $excl = touch_file($dir, 'excluded.t');

    my $finder = App::Yath2::Finder->new(
        search       => [$dir],
        exclude_files => [$excl],
    );
    my $files = $finder->find_files([]);

    is(scalar @$files, 1, 'one file remains');
    is($files->[0]->file, $keep, 'kept the right file');
};

subtest '--exclude-patterns skips matching files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    touch_file($dir, 'unit_foo.t');
    touch_file($dir, 'integration_bar.t');
    touch_file($dir, 'other.t');

    my $finder = App::Yath2::Finder->new(
        search           => [$dir],
        exclude_patterns => [qr/integration/],
    );
    my $files = $finder->find_files([]);

    is(scalar @$files, 2, 'two non-matching files remain');
    my $excluded = grep { $_->file =~ /integration/ } @$files;
    ok(!$excluded, 'excluded file absent');
};

subtest '--exclude-list reads exclusions from a file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $keep = touch_file($dir, 'keep.t');
    my $excl = touch_file($dir, 'listed.t');

    my $list_file = File::Spec->catfile($dir, 'exclusions.txt');
    open my $fh, '>', $list_file or die "write $list_file: $!";
    print $fh "# a comment\n";
    print $fh "$excl\n";
    close $fh;

    my $finder = App::Yath2::Finder->new(
        search        => [$dir],
        exclude_lists => [$list_file],
    );
    my $files = $finder->find_files([]);

    is(scalar @$files, 1, 'one file survives exclusion list');
    is($files->[0]->file, $keep, 'correct file kept');
};

subtest 'default_search is used when no explicit search given' => sub {
    my $base = tempdir(CLEANUP => 1);
    my $tdir = File::Spec->catdir($base, 't');
    make_path($tdir);
    touch_file($tdir, 'sample.t');

    my $finder = App::Yath2::Finder->new(default_search => [$tdir]);
    my $files = $finder->find_files([]);

    is(scalar @$files, 1, 'found file via default_search');
};

subtest 'no tests found when search is empty and no default' => sub {
    my $finder = App::Yath2::Finder->new();
    my $ok  = eval { $finder->find_files([]); 1 };
    my $err = $@;
    ok(!$ok, 'dies on empty search');
    like($err, qr/search is empty/i, 'mentions empty search');
};

done_testing;

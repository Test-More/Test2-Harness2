use strict;
use warnings;
use Test2::V0;

use File::Temp qw/tempfile tempdir/;

# ---------------------------------------------------------------------------
# Factory: creates Stat reloader by default (Linux::Inotify2 not expected
# in most test environments; we test Stat directly anyway)
# ---------------------------------------------------------------------------
subtest 'factory creates a Reloader subclass' => sub {
    require Test2::Harness2::Reloader;

    my $r = Test2::Harness2::Reloader->new();
    isa_ok($r, ['Test2::Harness2::Reloader'], "got a Reloader subclass");

    # Must be either Stat or Inotify2
    my $class = ref($r);
    ok(
               $class eq 'Test2::Harness2::Reloader::Stat'
            || $class eq 'Test2::Harness2::Reloader::Inotify2',
        "class is a known backend ($class)"
    );
};

# ---------------------------------------------------------------------------
# Stat backend: basic construction
# ---------------------------------------------------------------------------
subtest 'Stat: basic construction' => sub {
    require Test2::Harness2::Reloader::Stat;

    my $r = Test2::Harness2::Reloader::Stat->new();
    isa_ok($r, ['Test2::Harness2::Reloader'],       "isa Reloader");
    isa_ok($r, ['Test2::Harness2::Reloader::Stat'], "isa Reloader::Stat");
    is(ref($r->restrict), 'ARRAY', "restrict is arrayref");
};

# ---------------------------------------------------------------------------
# Stat: start() and changed_files() with no changes returns []
# ---------------------------------------------------------------------------
subtest 'Stat: start and changed_files no changes' => sub {
    require Test2::Harness2::Reloader::Stat;

    my $dir = tempdir(CLEANUP => 1);
    my ($fh, $file) = tempfile(DIR => $dir, SUFFIX => '.pm', UNLINK => 1);
    print $fh "1;\n";
    close $fh;

    my $r = Test2::Harness2::Reloader::Stat->new();
    $r->watch($file);
    $r->start();

    my $changed = $r->changed_files();
    is(ref($changed),    'ARRAY', "changed_files returns arrayref");
    is(scalar @$changed, 0,       "no changes detected immediately after start");
};

# ---------------------------------------------------------------------------
# Stat: detect file modification
# ---------------------------------------------------------------------------
subtest 'Stat: detect file modification' => sub {
    require Test2::Harness2::Reloader::Stat;

    my $dir = tempdir(CLEANUP => 1);
    my ($fh, $file) = tempfile(DIR => $dir, SUFFIX => '.pm', UNLINK => 1);
    print $fh "1;\n";
    close $fh;

    my $r = Test2::Harness2::Reloader::Stat->new();
    $r->watch($file);
    $r->start();

    # Drain any initial "no change" reading and reset the last-check stamp so
    # the next call is not throttled.
    $r->changed_files();
    $r->{Test2::Harness2::Reloader::Stat::_LAST_CHECK()} = 0;

    # Sleep > 1 second so mtime changes
    sleep 1.1;

    # Modify the file
    open(my $wfh, '>', $file) or die "Cannot write $file: $!";
    print $wfh "# modified\n1;\n";
    close $wfh;

    # Reset throttle again before the detection call
    $r->{Test2::Harness2::Reloader::Stat::_LAST_CHECK()} = 0;

    my $changed = $r->changed_files();
    is(ref($changed),    'ARRAY', "changed_files returns arrayref");
    is(scalar @$changed, 1,       "one changed file detected");
    is($changed->[0],    $file,   "correct file reported as changed");
};

# ---------------------------------------------------------------------------
# Stat: watch multiple files
# ---------------------------------------------------------------------------
subtest 'Stat: watch multiple files' => sub {
    require Test2::Harness2::Reloader::Stat;

    my $dir = tempdir(CLEANUP => 1);

    my ($fh1, $file1) = tempfile(DIR => $dir, SUFFIX => '.pm', UNLINK => 1);
    print $fh1 "1;\n";
    close $fh1;

    my ($fh2, $file2) = tempfile(DIR => $dir, SUFFIX => '.pm', UNLINK => 1);
    print $fh2 "1;\n";
    close $fh2;

    my ($fh3, $file3) = tempfile(DIR => $dir, SUFFIX => '.pm', UNLINK => 1);
    print $fh3 "1;\n";
    close $fh3;

    my $r = Test2::Harness2::Reloader::Stat->new();
    $r->watch($file1);
    $r->watch($file2);
    $r->watch($file3);
    $r->start();

    # Consume initial check
    $r->changed_files();
    $r->{Test2::Harness2::Reloader::Stat::_LAST_CHECK()} = 0;

    sleep 1.1;

    # Modify two of the three files
    open(my $w1, '>', $file1) or die "Cannot write $file1: $!";
    print $w1 "# changed\n1;\n";
    close $w1;

    open(my $w2, '>', $file2) or die "Cannot write $file2: $!";
    print $w2 "# changed\n1;\n";
    close $w2;

    $r->{Test2::Harness2::Reloader::Stat::_LAST_CHECK()} = 0;

    my $changed = $r->changed_files();
    is(ref($changed),    'ARRAY', "changed_files returns arrayref");
    is(scalar @$changed, 2,       "two changed files detected");

    my %changed_set = map { $_ => 1 } @$changed;
    ok($changed_set{$file1},  "file1 reported changed");
    ok($changed_set{$file2},  "file2 reported changed");
    ok(!$changed_set{$file3}, "file3 not reported changed");
};

# ---------------------------------------------------------------------------
# Stat: watch() after start() also gets registered
# ---------------------------------------------------------------------------
subtest 'Stat: watch after start' => sub {
    require Test2::Harness2::Reloader::Stat;

    my $dir = tempdir(CLEANUP => 1);
    my ($fh, $file) = tempfile(DIR => $dir, SUFFIX => '.pm', UNLINK => 1);
    print $fh "1;\n";
    close $fh;

    my $r = Test2::Harness2::Reloader::Stat->new();
    $r->start();
    $r->watch($file);    # watch AFTER start

    $r->changed_files();
    $r->{Test2::Harness2::Reloader::Stat::_LAST_CHECK()} = 0;

    sleep 1.1;

    open(my $wfh, '>', $file) or die "Cannot write $file: $!";
    print $wfh "# modified\n1;\n";
    close $wfh;

    $r->{Test2::Harness2::Reloader::Stat::_LAST_CHECK()} = 0;

    my $changed = $r->changed_files();
    is(scalar @$changed, 1, "change detected for file watched after start");
};

done_testing;

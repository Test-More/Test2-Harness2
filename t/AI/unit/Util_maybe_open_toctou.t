use Test2::V0;
use File::Temp qw/tempfile tempdir/;

use Test2::Harness2::Util qw/maybe_open_file maybe_read_file/;

# Regression coverage for TODO-154 finding 47: maybe_open_file / maybe_read_file must
# return undef (not confess) when the target does not exist or vanishes in the
# race between the decision to open and the open itself (ENOENT/ESTALE), so a
# teardown-racing poller degrades gracefully. Any OTHER open failure still throws.

my $missing = "/some/super/fake/path/that-must-not-exist-t154-$$";

subtest 'maybe_open_file on a missing path returns undef (no die)' => sub {
    my $fh;
    ok(lives { $fh = maybe_open_file($missing) }, "missing path does not die");
    is($fh, undef, "missing path -> undef");
};

subtest 'maybe_open_file on a directory with "<" returns undef (contract pin)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $fh;
    ok(lives { $fh = maybe_open_file($dir) }, "directory does not die");
    is($fh, undef, "directory with '<' -> undef (fstat rejects the non-plain handle)");
};

subtest 'maybe_read_file on a missing path returns undef' => sub {
    my $out;
    ok(lives { $out = maybe_read_file($missing) }, "missing path does not die");
    is($out, undef, "missing path -> undef");
};

subtest 'maybe_open_file on a missing .gz path returns undef' => sub {
    my $fh;
    ok(lives { $fh = maybe_open_file("$missing.gz") }, "missing .gz path does not die");
    is($fh, undef, "missing .gz path -> undef");
};

subtest 'a genuinely unreadable existing file still throws (not a race)' => sub {
    skip_all "cannot exercise the unreadable-file path as root (euid == 0)" if $> == 0;

    my ($fh, $file) = tempfile("t154-perm-XXXXXX", TMPDIR => 1, UNLINK => 1);
    print $fh "secret\n";
    close($fh);
    chmod(0000, $file) or skip_all "could not chmod 0000 the fixture";

    like(
        dies { maybe_open_file($file) },
        qr/Could not open file/,
        "an existing but unreadable file (EACCES) still confesses"
    );

    chmod(0600, $file);    # restore perms so UNLINK cleanup can remove it
};

done_testing;

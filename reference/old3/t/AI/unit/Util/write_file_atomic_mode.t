use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();
use Fcntl qw/:mode/;

use Test2::Harness2::Util qw/write_file_atomic_mode read_file/;

my $dir = tempdir(CLEANUP => 1);

# 1. Round-trip: content survives.
{
    my $path = File::Spec->catfile($dir, 'roundtrip');
    write_file_atomic_mode($path, 0600, "hello\nworld\n");
    is(read_file($path), "hello\nworld\n", 'content round-trips');
}

# 2. Multi-arg content is concatenated like print().
{
    my $path = File::Spec->catfile($dir, 'multi');
    write_file_atomic_mode($path, 0644, "a", "b", "c");
    is(read_file($path), 'abc', 'multi-arg content concatenates');
}

# 3. Final mode matches the requested mode under default umask.
{
    my $path = File::Spec->catfile($dir, 'mode_default');
    write_file_atomic_mode($path, 0600, "x");
    my $mode = (stat $path)[2] & 07777;
    is(sprintf('%04o', $mode), '0600', 'final mode is 0600 under default umask');
}

# 4. Final mode survives a hostile umask that would otherwise mask
#    owner bits. With umask 0277 and a naive sysopen(0600), the file
#    would land at 0400 (no owner-write). The helper must defeat that.
{
    my $path = File::Spec->catfile($dir, 'mode_hostile');
    my $old  = umask 0277;
    write_file_atomic_mode($path, 0600, "x");
    umask $old;
    my $mode = (stat $path)[2] & 07777;
    is(sprintf('%04o', $mode), '0600', 'final mode is 0600 under hostile umask 0277');
}

# 5. Group/other bits are exactly what was requested, even when umask
#    is 0 (i.e. the caller did NOT mask group/other and we still must
#    not over-grant).
{
    my $path = File::Spec->catfile($dir, 'mode_explicit');
    my $old  = umask 0;
    write_file_atomic_mode($path, 0640, "x");
    umask $old;
    my $mode = (stat $path)[2] & 07777;
    is(sprintf('%04o', $mode), '0640', 'final mode is exactly 0640 even when umask is 0');
}

# 6. No leftover .pend after a successful write.
{
    my $path = File::Spec->catfile($dir, 'no_pend');
    write_file_atomic_mode($path, 0600, "x");
    ok(!-e "${path}.pend", 'no leftover .pend after success');
}

# 7. Atomic semantics: a target that already exists is replaced, not
#    truncated mid-write. We approximate by writing twice and reading
#    back the second value.
{
    my $path = File::Spec->catfile($dir, 'replace');
    write_file_atomic_mode($path, 0600, "first");
    is(read_file($path), 'first', 'first write visible');
    write_file_atomic_mode($path, 0600, "second");
    is(read_file($path), 'second', 'second write replaces first');
    my $mode = (stat $path)[2] & 07777;
    is(sprintf('%04o', $mode), '0600', 'mode preserved across replacement');
}

# 8. Failure mode: missing target directory dies, no .pend left
#    behind.
{
    my $path = File::Spec->catfile($dir, 'no_such_subdir', 'file');
    like(
        dies { write_file_atomic_mode($path, 0600, "x") },
        qr/open .* for write/i,
        'dies when target directory does not exist',
    );
    ok(!-e "${path}.pend", 'no leftover .pend after failure');
}

# 9. Missing mode argument dies.
{
    my $path = File::Spec->catfile($dir, 'missing_mode');
    like(
        dies { write_file_atomic_mode($path, undef, "x") },
        qr/'mode' must be defined/,
        'dies when mode is undef',
    );
}

done_testing;

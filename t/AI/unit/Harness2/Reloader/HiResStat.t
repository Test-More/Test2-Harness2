use strict;
use warnings;

use Test2::V0;

use Cwd qw/abs_path/;
use File::Path qw/make_path/;
use File::Spec ();
use File::Temp qw/tempdir/;

use Test2::Harness2::Reloader::HiResStat;

# Bump a file's mtime past the current time so a Time::HiRes stat
# will see a change even when the test races inside one filesystem
# tick of the previous write.
sub bump_mtime {
    my ($path, $delta) = @_;
    $delta //= 2;
    my $now = time + $delta;
    utime($now, $now, $path) or die "utime $path: $!";
}

subtest 'construction defaults' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $rel = Test2::Harness2::Reloader::HiResStat->new(project_root => $tmp);

    is($rel->project_root, $tmp, 'project_root passed through');
    is($rel->poll_interval_secs, 0.25, 'poll_interval_secs defaults to 0.25');
    is($rel->debounce_secs, 0.25, 'debounce_secs defaults to 0.25');
    is(ref($rel->watch_paths), 'ARRAY', 'watch_paths is an arrayref');
    is($rel->watch_paths, [$tmp], 'watch_paths defaults to [project_root]');
    is($rel->last_reload_at, 0, 'last_reload_at starts at 0');
    is($rel->last_error, undef, 'last_error starts undef');
};

subtest 'watch_paths override' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/a", "$tmp/b");

    my $rel = Test2::Harness2::Reloader::HiResStat->new(
        project_root => $tmp,
        watch_paths  => ["$tmp/a", "$tmp/b"],
    );
    is($rel->watch_paths, ["$tmp/a", "$tmp/b"], 'caller override respected');
};

subtest 'do_reload detects mtime change and reloads' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    push @INC => $tmp;

    my $path = "$tmp/HiResReloadFix.pm";
    open(my $fh, '>', $path) or die "open $path: $!";
    print $fh <<'EOM';
package HiResReloadFix;
use strict; use warnings;
sub greet { 'hello' }
1;
EOM
    close $fh;

    require HiResReloadFix;
    is(HiResReloadFix::greet(), 'hello', 'initial load works');

    my $rel = Test2::Harness2::Reloader::HiResStat->new(
        project_root  => $tmp,
        watch_paths   => [$tmp],
        debounce_secs => 0,
    );

    # First tick: snapshot mtimes, no reload.
    $rel->do_reload(undef);
    is($rel->last_reload_at, 0, 'first tick is a snapshot, no reload');
    is($rel->last_error, undef, 'no error from snapshot tick');

    # Rewrite the module with a different greet().
    open($fh, '>', $path) or die "rewrite $path: $!";
    print $fh <<'EOM';
package HiResReloadFix;
use strict; use warnings;
sub greet { 'world' }
1;
EOM
    close $fh;
    bump_mtime($path);

    $rel->do_reload(undef);
    is(HiResReloadFix::greet(), 'world', 'reload picked up new source');
    ok($rel->last_reload_at > 0, 'last_reload_at recorded');
    is($rel->last_error, undef, 'no error after success');
};

subtest 'do_reload is a no-op when nothing changed' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    push @INC => $tmp;

    my $path = "$tmp/HiResQuietFix.pm";
    open(my $fh, '>', $path) or die "open $path: $!";
    print $fh <<'EOM';
package HiResQuietFix;
use strict; use warnings;
sub n { 1 }
1;
EOM
    close $fh;

    require HiResQuietFix;
    is(HiResQuietFix::n(), 1, 'initial load works');

    my $rel = Test2::Harness2::Reloader::HiResStat->new(
        project_root  => $tmp,
        watch_paths   => [$tmp],
        debounce_secs => 0,
    );

    # First tick: snapshot.
    $rel->do_reload(undef);
    is($rel->last_reload_at, 0, 'first tick is a snapshot');

    # Second tick with no file change: still no reload.
    $rel->do_reload(undef);
    is($rel->last_reload_at, 0, 'second tick is a no-op');
    is($rel->last_error, undef, 'no error');
};

subtest 'reload failure records last_error and does not throw' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    push @INC => $tmp;

    my $path = "$tmp/HiResBadFix.pm";
    open(my $fh, '>', $path) or die "open $path: $!";
    print $fh <<'EOM';
package HiResBadFix;
use strict; use warnings;
sub ok { 1 }
1;
EOM
    close $fh;

    require HiResBadFix;
    is(HiResBadFix::ok(), 1, 'initial load works');

    my $rel = Test2::Harness2::Reloader::HiResStat->new(
        project_root  => $tmp,
        watch_paths   => [$tmp],
        debounce_secs => 0,
    );

    # Snapshot tick.
    $rel->do_reload(undef);

    # Rewrite with a syntax error.
    open($fh, '>', $path) or die "rewrite $path: $!";
    print $fh "package HiResBadFix; this is not perl\n";
    close $fh;
    bump_mtime($path);

    my $ok = eval { $rel->do_reload(undef); 1 };
    my $err = $@;
    ok($ok, 'do_reload does not throw on compile error') or diag $err;
    like($rel->last_error, qr/.+/, 'last_error recorded');
    is($rel->last_reload_at, 0, 'last_reload_at unchanged on failure');
};

done_testing;

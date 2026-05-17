use strict;
use warnings;

use Test2::Require::Module 'Linux::Inotify2';
use Test2::V0;

use Cwd qw/abs_path/;
use File::Path qw/make_path/;
use File::Spec ();
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Reloader::INotify;

# Pump do_reload up to N times waiting briefly between calls so the
# inotify queue has a chance to deliver events. Caps at 200ms total.
sub pump {
    my ($rel, $max_ms) = @_;
    $max_ms //= 200;
    my $deadline = time + ($max_ms / 1000);
    while (time < $deadline) {
        $rel->do_reload(undef);
        return if $rel->last_reload_at || $rel->last_error;
        sleep 0.02;
    }
}

subtest 'croak when Linux::Inotify2 is missing' => sub {
    # Stub the inc loader for Linux/Inotify2.pm so the require inside
    # init() fails even though the real module is installed.
    local @INC = (sub {
        my (undef, $file) = @_;
        return unless $file eq 'Linux/Inotify2.pm';
        die "Can't locate Linux/Inotify2.pm in stub\n";
    }, @INC);

    # Force a fresh require attempt.
    local %INC = %INC;
    delete $INC{'Linux/Inotify2.pm'};

    my $tmp = tempdir(CLEANUP => 1);
    my $ok = eval {
        Test2::Harness2::Reloader::INotify->new(project_root => $tmp);
        1;
    };
    my $err = $@;
    ok(!$ok, 'construction failed when Linux::Inotify2 is unavailable');
    like(
        $err,
        qr/Linux::Inotify2 is required for the inotify reloader/,
        'croak message identifies the missing dependency',
    );
};

subtest 'construction defaults' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $rel = Test2::Harness2::Reloader::INotify->new(project_root => $tmp);

    is($rel->project_root, $tmp, 'project_root passed through');
    is($rel->debounce_secs, 0.25, 'debounce_secs defaults to 0.25');
    is(ref($rel->watch_paths), 'ARRAY', 'watch_paths is an arrayref');
    is($rel->watch_paths, [$tmp], 'watch_paths defaults to [project_root]');
    is($rel->last_reload_at, 0, 'last_reload_at starts at 0');
    is($rel->last_error, undef, 'last_error starts undef');
};

subtest 'do_reload reloads after a write' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    push @INC => $tmp;

    my $path = "$tmp/INotifyReloadFix.pm";
    open(my $fh, '>', $path) or die "open $path: $!";
    print $fh <<'EOM';
package INotifyReloadFix;
use strict; use warnings;
sub greet { 'hello' }
1;
EOM
    close $fh;

    require INotifyReloadFix;
    is(INotifyReloadFix::greet(), 'hello', 'initial load works');

    my $rel = Test2::Harness2::Reloader::INotify->new(
        project_root  => $tmp,
        watch_paths   => [$tmp],
        debounce_secs => 0,
    );

    # Rewrite the module with a different greet() and touch its mtime.
    open($fh, '>', $path) or die "rewrite $path: $!";
    print $fh <<'EOM';
package INotifyReloadFix;
use strict; use warnings;
sub greet { 'world' }
1;
EOM
    close $fh;
    my $now = time + 2;
    utime($now, $now, $path) or die "utime: $!";

    pump($rel);

    is(INotifyReloadFix::greet(), 'world', 'reload picked up new source');
    ok($rel->last_reload_at > 0, 'last_reload_at recorded');
    is($rel->last_error, undef, 'no error after success');
};

subtest 'compile-error path records last_error' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    push @INC => $tmp;

    my $path = "$tmp/INotifyBadFix.pm";
    open(my $fh, '>', $path) or die "open $path: $!";
    print $fh <<'EOM';
package INotifyBadFix;
use strict; use warnings;
sub ok { 1 }
1;
EOM
    close $fh;

    require INotifyBadFix;
    is(INotifyBadFix::ok(), 1, 'initial load works');

    my $rel = Test2::Harness2::Reloader::INotify->new(
        project_root  => $tmp,
        watch_paths   => [$tmp],
        debounce_secs => 0,
    );

    # Rewrite with a syntax error and bump mtime.
    open($fh, '>', $path) or die "rewrite $path: $!";
    print $fh "package INotifyBadFix; this is not perl\n";
    close $fh;
    my $now = time + 2;
    utime($now, $now, $path) or die "utime: $!";

    my $ok = eval { pump($rel); 1 };
    my $err = $@;
    ok($ok, 'do_reload does not throw on compile error') or diag $err;
    like($rel->last_error, qr/.+/, 'last_error recorded');
    is($rel->last_reload_at, 0, 'last_reload_at unchanged on failure');
};

done_testing;

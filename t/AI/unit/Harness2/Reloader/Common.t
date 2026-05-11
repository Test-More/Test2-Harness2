use strict;
use warnings;

use Test2::V0;

use File::Path qw/make_path/;
use File::Spec ();
use File::Temp qw/tempdir/;

use Test2::Harness2::Reloader::Common;

subtest 'project root via .git marker' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/foo/bar/baz");
    mkdir "$tmp/foo/.git";

    my $found = Test2::Harness2::Reloader::Common->_project_root("$tmp/foo/bar/baz");
    is($found, "$tmp/foo", '.git marker locates project root');
};

subtest 'project root via .yath.rc marker' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/foo/bar/baz");
    open(my $fh, '>', "$tmp/foo/.yath.rc") or die;
    close $fh;

    my $found = Test2::Harness2::Reloader::Common->_project_root("$tmp/foo/bar/baz");
    is($found, "$tmp/foo", '.yath.rc marker locates project root');
};

subtest '_filter_inc keeps entries under project_root' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/inside");

    open(my $fh, '>', "$tmp/inside/IncFilter.pm") or die;
    print $fh "package IncFilter; 1;\n";
    close $fh;

    require "$tmp/inside/IncFilter.pm";
    is($INC{"$tmp/inside/IncFilter.pm"}, "$tmp/inside/IncFilter.pm",
        'fixture loaded into %INC');

    my $rel = Test2::Harness2::Reloader::Common->new(project_root => $tmp);
    my $hits = $rel->_filter_inc;
    my @keys = sort map { $_->[0] } @$hits;
    my @under = grep { /^\Q$tmp\E/ } @keys;
    ok(@under >= 1, 'at least one entry under project_root');

    # Strict.pm (or any core .pm loaded above) should be excluded.
    ok(!(grep { $_ eq 'strict.pm' } @keys), 'core entries outside project_root excluded');
};

subtest '_attempt_in_place_reload reloads a changing module' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    push @INC, $tmp;

    my $path = "$tmp/ReloadFix.pm";
    open(my $fh, '>', $path) or die;
    print $fh <<'EOM';
package ReloadFix;
use strict; use warnings;
sub greet { 'hello' }
1;
EOM
    close $fh;

    require ReloadFix;
    is(ReloadFix::greet(), 'hello', 'initial load works');

    # Rewrite with a changed return value.
    open($fh, '>', $path) or die;
    print $fh <<'EOM';
package ReloadFix;
use strict; use warnings;
sub greet { 'world' }
1;
EOM
    close $fh;

    my $rel = Test2::Harness2::Reloader::Common->new(project_root => $tmp);
    my ($ok, $err) = $rel->_attempt_in_place_reload($path);
    ok($ok, 'in-place reload succeeded') or diag $err;
    is(ReloadFix::greet(), 'world', 'reload picked up new source');

    ok($rel->last_reload_at > 0, 'last_reload_at recorded');
    is($rel->last_error, undef, 'no error after success');
};

subtest '_attempt_in_place_reload captures compile errors' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    push @INC, $tmp;

    my $path = "$tmp/BadReload.pm";
    open(my $fh, '>', $path) or die;
    print $fh "package BadReload; use strict; use warnings; sub ok { 1 } 1;\n";
    close $fh;

    require BadReload;
    is(BadReload::ok(), 1, 'initial load works');

    # Rewrite with a syntax error.
    open($fh, '>', $path) or die;
    print $fh "package BadReload; this is not perl\n";
    close $fh;

    my $rel = Test2::Harness2::Reloader::Common->new(project_root => $tmp);
    my ($ok, $err) = $rel->_attempt_in_place_reload($path);
    ok(!$ok, 'compile error returns false');
    like($err, qr/syntax|error|String found|require/i, 'error message is captured');
    like($rel->last_error, qr/.+/, 'last_error set');
};

subtest 'find_churn parses HARNESS-CHURN markers' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $path = "$tmp/churn.pm";
    open(my $fh, '>', $path) or die;
    print $fh <<'EOM';
package ChurnFix;
use strict; use warnings;

# HARNESS-CHURN-START
sub a { 1 }
# HARNESS-CHURN-STOP

sub b { 2 }

# HARNESS-CHURN-START
sub c { 3 }
sub d { 4 }
# HARNESS-CHURN-STOP

1;
EOM
    close $fh;

    my $rel = Test2::Harness2::Reloader::Common->new(project_root => $tmp);
    my @churn = $rel->find_churn($path);
    is(scalar(@churn), 2, 'found two CHURN sections');
    like($churn[0][1], qr/sub a/, 'first section captures body');
    like($churn[1][1], qr/sub c/, 'second section captures body');
    like($churn[1][1], qr/sub d/, 'second section captures both subs');
};

subtest '_attempt_churn_reload re-evals only churn blocks' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    push @INC, $tmp;

    my $path = "$tmp/ChurnHot.pm";
    open(my $fh, '>', $path) or die;
    print $fh <<'EOM';
package ChurnHot;
use strict; use warnings;

our $loaded_at = 'original';

# HARNESS-CHURN-START
sub greet { 'hello' }
# HARNESS-CHURN-STOP

1;
EOM
    close $fh;

    require ChurnHot;
    is(ChurnHot::greet(), 'hello', 'initial load works');
    is($ChurnHot::loaded_at, 'original', 'module-level state set');

    # Mutate state, then rewrite only the CHURN block. The
    # module-level state outside CHURN must survive.
    $ChurnHot::loaded_at = 'mutated';

    open($fh, '>', $path) or die;
    print $fh <<'EOM';
package ChurnHot;
use strict; use warnings;

our $loaded_at = 'original';

# HARNESS-CHURN-START
sub greet { 'world' }
# HARNESS-CHURN-STOP

1;
EOM
    close $fh;

    my $rel = Test2::Harness2::Reloader::Common->new(project_root => $tmp);
    my ($ok, $err) = $rel->_attempt_churn_reload($path);
    ok($ok, 'churn reload succeeded') or diag $err;
    is(ChurnHot::greet(), 'world', 'churn block reloaded');
    is($ChurnHot::loaded_at, 'mutated',
        'module-level state outside CHURN preserved');
};

subtest 'request_restart honors exec_cb (no real exec)' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $rel = Test2::Harness2::Reloader::Common->new(project_root => $tmp);

    my @captured_argv;
    my $captured_payload;

    # Fake $svc carrying a fake client that records messages.
    my $svc = bless {}, 'Test2::Test::FakeSvc';
    {
        no strict 'refs';
        *Test2::Test::FakeSvc::client = sub {
            return bless { svc => $_[0] }, 'Test2::Test::FakeClient';
        };
        *Test2::Test::FakeSvc::preload_name = sub { 'mypl' };
        *Test2::Test::FakeSvc::scope        = sub { 'global' };
        *Test2::Test::FakeSvc::run_id       = sub { undef };
        *Test2::Test::FakeClient::send_message = sub {
            my ($self, $peer, $msg) = @_;
            $captured_payload = $msg;
            return 1;
        };
    }

    $rel->request_restart($svc, exec_cb => sub {
        @captured_argv = @{$_[0]};
        return 'fake-exec';
    });

    ok(@captured_argv >= 2, 'exec_cb received argv');
    is($captured_argv[0], $^X, 'first argv entry is perl interpreter');
    ok($captured_payload, 'preload_restarting IPC sent');
    is($captured_payload->{kind}, 'preload_restarting', 'IPC kind correct');
    is($captured_payload->{preload_name}, 'mypl', 'preload_name carried');
};

done_testing;

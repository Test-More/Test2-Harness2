use Test2::V0 -target => 'App::Yath2::Plugin::Git';
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression coverage for ticket TODO-107 (P0):
#   _changed_diff($base) looped `git merge-base --is-ancestor $from $base`
#   appending "^" without ever checking $?. A typo'd/nonexistent change base,
#   an orphan/unrelated branch, or a shallow clone (HEAD^..^ past the shallow
#   boundary) makes git exit non-1 forever -> an unbounded fork loop that spams
#   'fatal: bad revision' and never starts the tests. The fix: validate the base
#   up front, die on any non-1 merge-base exit (surfacing git's error), and bound
#   the walk by the HEAD commit count.

use App::Yath2::Plugin::Git;
use IPC::Cmd qw/can_run/;
use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;
use Time::HiRes qw/time/;

my $SCRIPT = __FILE__;
$SCRIPT =~ s/\.t$/\.script/;

sub drain {
    my ($it) = @_;
    my @lines;
    while (defined(my $l = $it->())) { push @lines, $l }
    return @lines;
}

# Every case below must finish fast; a regression re-introduces an unbounded loop.
my $BOUND = 20;    # seconds

subtest 'invalid change base dies fast, naming the ref (real git)' => sub {
    my $git = can_run('git') or skip_all "git not available";

    my $dir = tempdir(CLEANUP => 1);
    my $cwd = getcwd();

    my $run = sub { scalar `cd "$dir" && $git @_ 2>&1` };
    $run->('init', '-q');
    $run->('config', 'user.email', 'test@example.com');
    $run->('config', 'user.name', 'Test');
    $run->('commit', '--allow-empty', '-q', '-m', 'first');
    $run->('commit', '--allow-empty', '-q', '-m', 'second');

    local $ENV{GIT_COMMAND};    # use the real git
    local $ENV{GIT_DIR};

    my $ok = eval { chdir($dir) or die "chdir: $!"; 1 };
    chdir($cwd) unless $ok;
    ok($ok, "chdir into temp repo") or return;

    my $start = time;
    my $err;
    my $lived = eval { $CLASS->_changed_diff('no-such-ref-xyz'); 1 };
    $err = $@;
    my $elapsed = time - $start;
    chdir($cwd);

    ok(!$lived, "invalid change base dies instead of looping");
    like($err, qr/no-such-ref-xyz/, "die message names the bogus ref");
    like($err, qr/change-base/i,    "die message points at --git-change-base");
    ok($elapsed < $BOUND, "died promptly (${elapsed}s < ${BOUND}s), not an unbounded loop");
};

subtest 'valid ancestor base still resolves (real git)' => sub {
    my $git = can_run('git') or skip_all "git not available";

    my $dir = tempdir(CLEANUP => 1);
    my $cwd = getcwd();

    my $run = sub { scalar `cd "$dir" && $git @_ 2>&1` };
    $run->('init', '-q');
    $run->('config', 'user.email', 'test@example.com');
    $run->('config', 'user.name', 'Test');
    $run->('commit', '--allow-empty', '-q', '-m', 'first');

    my $base_sha = $run->('rev-parse', 'HEAD');
    chomp $base_sha;

    # Second commit adds a marker file; tree left clean afterward.
    open(my $fh, '>', "$dir/b_marker.pl") or die "open: $!";
    print $fh "1;\n";
    close($fh);
    $run->('add', 'b_marker.pl');
    $run->('commit', '-q', '-m', 'second');

    local $ENV{GIT_COMMAND};
    local $ENV{GIT_DIR};

    my $ok = eval { chdir($dir) or die "chdir: $!"; 1 };
    chdir($cwd) unless $ok;
    ok($ok, "chdir into temp repo") or return;

    my ($key, $sub);
    my $start = time;
    my $lived = eval { ($key, $sub) = $CLASS->_changed_diff($base_sha); 1 };
    my $err = $@;
    my $elapsed = time - $start;
    my @out = $lived ? drain($sub) : ();
    chdir($cwd);

    ok($lived, "valid ancestor base resolves without dying") or diag($err);
    is($key, 'line_sub', "returns a line_sub pair");
    ok((grep { /b_marker\.pl/ } @out), "diff from the resolved base includes the changed file")
        or diag(join('', @out));
    ok($elapsed < $BOUND, "resolved promptly (${elapsed}s < ${BOUND}s)");
};

subtest 'merge-base bad-revision exit (shallow boundary) dies, does not loop' => sub {
    local $ENV{GIT_COMMAND}  = $SCRIPT;
    local $ENV{BUG107_MODE}  = 'badrev';

    my $start = time;
    my $lived = eval { $CLASS->_changed_diff('GOOD'); 1 };
    my $err = $@;
    my $elapsed = time - $start;

    ok(!$lived, "non-1 merge-base exit is fatal, not looped");
    like($err, qr/merge-base/,    "die message identifies the failing command");
    like($err, qr/bad revision/,  "die message surfaces git's own error");
    ok($elapsed < $BOUND, "died promptly (${elapsed}s < ${BOUND}s)");
};

subtest 'orphan/unrelated branch is bounded by commit count' => sub {
    local $ENV{GIT_COMMAND}  = $SCRIPT;
    local $ENV{BUG107_MODE}  = 'orphan';    # merge-base always exits 1

    my $start = time;
    my $lived = eval { $CLASS->_changed_diff('GOOD'); 1 };
    my $err = $@;
    my $elapsed = time - $start;

    ok(!$lived, "never-an-ancestor base terminates via the iteration bound");
    like($err, qr/unrelated branch|within \d+ commit/i, "die message explains the bound");
    ok($elapsed < $BOUND, "died promptly (${elapsed}s < ${BOUND}s), not an unbounded loop");
};

done_testing;

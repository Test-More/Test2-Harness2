use Test2::V0 -target => 'App::Yath2::Plugin::Git';
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression coverage for ticket #150:
#   (78) git_output must not deadlock when git writes more than a pipe's worth of
#        stderr; it now uses Capture::Tiny instead of a hand-rolled pipe pair.
#   (82) the clean-tree --changed-only fallback (_changed_diff with no base) must
#        select the last commit (HEAD^) instead of returning empty / dying.

use App::Yath2::Plugin::Git;
use IPC::Cmd qw/can_run/;
use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;
use Capture::Tiny qw/capture_stderr/;

my $SCRIPT = __FILE__;
$SCRIPT =~ s/\.t$/\.script/;

sub drain {
    my ($it) = @_;
    my @lines;
    while (defined(my $l = $it->())) { push @lines, $l }
    return @lines;
}

subtest 'git_output does not deadlock on >64KB stderr' => sub {
    local $ENV{GIT_COMMAND} = $SCRIPT;

    # If this hangs, the old pipe-capacity deadlock has regressed. Capture::Tiny
    # buffers both streams to temp handles, so it completes regardless of size.
    my $it = $CLASS->git_output('bigerr');
    my @lines = drain($it);

    is(\@lines, ["line one\n", "line two\n"], "stdout lines returned with trailing newlines preserved");
};

subtest 'git_output surfaces stderr only on failure (lenient, non-dying)' => sub {
    local $ENV{GIT_COMMAND} = $SCRIPT;

    # exit 0 with big stderr => stderr swallowed (no noise on every run).
    my $quiet = capture_stderr { drain($CLASS->git_output('bigerr')) };
    is($quiet, '', "successful command does not emit its stderr");

    # non-zero exit => stderr forwarded, but still no die (returns normally).
    my @out;
    my $noisy = capture_stderr { @out = drain($CLASS->git_output('failerr')) };
    like($noisy, qr/boom/, "failed command forwards its stderr to STDERR");
    is(\@out, [], "failed command yields no stdout lines, does not die");
};

subtest 'clean-tree _changed_diff falls back to HEAD^ (last commit)' => sub {
    local $ENV{GIT_COMMAND} = $SCRIPT;

    # Clean tree: `git diff --quiet HEAD` exits 0 -> diff from HEAD^.
    {
        local $ENV{FAKE_DIRTY};
        my ($key, $sub) = $CLASS->_changed_diff(undef);
        is($key, 'line_sub', "returns a line_sub pair");
        my @out = drain($sub);
        is(\@out, ["DIFF-FROM HEAD^\n"], "clean tree diffs the last commit (HEAD^), not empty HEAD");
    }

    # Dirty tree: `git diff --quiet HEAD` exits 1 -> keep HEAD.
    {
        local $ENV{FAKE_DIRTY} = 1;
        my ($key, $sub) = $CLASS->_changed_diff(undef);
        my @out = drain($sub);
        is(\@out, ["DIFF-FROM HEAD\n"], "dirty tree keeps HEAD");
    }
};

subtest 'real git: clean-tree changed-only selects the last commit' => sub {
    my $git = can_run('git') or skip_all "git not available";

    my $dir = tempdir(CLEANUP => 1);
    my $cwd = getcwd();

    my $run = sub {
        my $out = `cd "$dir" && $git @_ 2>&1`;
        return $out;
    };

    $run->('init', '-q');
    $run->('config', 'user.email', 'test@example.com');
    $run->('config', 'user.name', 'Test');
    $run->('commit', '--allow-empty', '-q', '-m', 'first');

    # Second commit adds b_marker.pl; tree left clean afterward.
    open(my $fh, '>', "$dir/b_marker.pl") or die "open: $!";
    print $fh "1;\n";
    close($fh);
    $run->('add', 'b_marker.pl');
    $run->('commit', '-q', '-m', 'second');

    local $ENV{GIT_COMMAND};    # use the real git
    local $ENV{GIT_DIR};

    my $ok = eval {
        chdir($dir) or die "chdir: $!";
        1;
    };
    chdir($cwd) unless $ok;
    ok($ok, "chdir into temp repo") or return;

    my ($key, $sub) = $CLASS->_changed_diff(undef);
    my @out = drain($sub);
    chdir($cwd);

    is($key, 'line_sub', "line_sub pair from real git");
    ok((grep { /b_marker\.pl/ } @out), "clean-tree changed-only picked up the last commit's file")
        or diag(join('', @out));
};

done_testing;

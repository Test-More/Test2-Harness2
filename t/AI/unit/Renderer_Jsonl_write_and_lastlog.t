use Test2::V0;
use feature 'signatures';
no warnings 'experimental::signatures';
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

use Cwd qw/getcwd/;
use File::Temp qw/tempdir/;

use App::Yath2::Renderer::Jsonl;
use App::Yath2::Options::Logger;

# Regression coverage for ticket TODO-143 (Jsonl renderer / lastlog bundle):
#   * finish() must CHECK close() -- a failed flush/close (disk full mid-run)
#     means the log is corrupt/truncated, so it warns and MUST NOT print the
#     falsely-reassuring "Wrote log file" success line (audit finding 57).
#   * the lastlog symlink sweep must use -l/-e (not -f) so a DANGLING lastlog
#     link (its old target deleted) is swept and re-pointed at the NEW log,
#     rather than silently left pointing at the deleted file (finding 20).
#   * App::Yath2::Options::Logger::_maybe_lastlog re-points lastlog.sqlite even
#     when a stale/dangling link is present (finding 84).

# Field keys (HashBase lower-cases the attribute name; '+field' still yields the
# constant sub but we set the plain hash slots directly).
my $FH   = App::Yath2::Renderer::Jsonl->can('FH')->();
my $FILE = App::Yath2::Renderer::Jsonl->can('FILE')->();

# A settings mock whose jsonl group is absent, so new()/init()/_open is a no-op
# and we can drive finish() against a filehandle we install by hand.
sub bare_settings {
    return mock {} => (add => [check_group => sub { 0 }]);
}

subtest finish_close_failure_suppresses_success => sub {
    # /dev/full accepts opens but fails writes with ENOSPC; stdio buffers the
    # small "null\n" so the failure surfaces at close() -- exactly the disk-full
    # path the fix guards.
    open(my $fh, '>', '/dev/full') or skip_all "No writable /dev/full on this platform: $!";

    my $r = App::Yath2::Renderer::Jsonl->new(settings => bare_settings());
    $r->{$FH}   = $fh;
    $r->{$FILE} = '/dev/full';

    my $out = '';
    my $warnings;
    {
        open(my $cap, '>', \$out) or die "capture STDOUT: $!";
        my $old = select($cap);
        $warnings = warnings { $r->finish };
        select($old);
    }

    is(scalar(@$warnings), 1, "finish() warned once about the failed write");
    like($warnings->[0], qr/Failed writing log file '\/dev\/full'/, "  ... naming the file");
    unlike($out, qr/Wrote log file/, "the 'Wrote log file' success line is suppressed on a close failure");
};

subtest finish_success_reports_wrote => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/run.jsonl";
    open(my $fh, '>', $log) or die "open $log: $!";

    my $r = App::Yath2::Renderer::Jsonl->new(settings => bare_settings());
    $r->{$FH}   = $fh;
    $r->{$FILE} = $log;

    my $out = '';
    {
        open(my $cap, '>', \$out) or die "capture STDOUT: $!";
        my $old = select($cap);
        $r->finish;
        select($old);
    }

    like($out, qr/\QWrote log file: $log\E/, "a clean close still reports 'Wrote log file'");
};

subtest dangling_lastlog_is_swept_and_repointed => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/run.jsonl";

    # Drive _open with a jsonl settings group pointing at $log (uncompressed).
    my $jsonl = mock {} => (add => [
        file  => sub { $log },
        bzip2 => sub { 0 },
        gzip  => sub { 0 },
    ]);
    my $settings = mock {} => (add => [
        check_group => sub ($self, $g) { $g eq 'jsonl' ? 1 : 0 },
        jsonl       => sub { $jsonl },
    ]);

    my $start = getcwd();
    chdir($dir) or die "chdir $dir: $!";
    my $ok = eval {
        # A DANGLING lastlog link: its old target was removed. -f is false for it,
        # so the pre-fix sweep skipped it and symlink() then failed EEXIST.
        symlink("./deleted-old.jsonl", "./lastlog.jsonl") or die "symlink setup: $!";
        ok(-l "./lastlog.jsonl" && !-e "./lastlog.jsonl", "precondition: lastlog.jsonl is a dangling symlink");

        my $warnings = warnings {
            App::Yath2::Renderer::Jsonl->new(settings => $settings);  # init -> _open
        };
        is($warnings, [], "no warnings while re-pointing the dangling lastlog link");

        ok(-l "./lastlog.jsonl", "lastlog.jsonl is still a symlink");
        ok(-e "./lastlog.jsonl", "lastlog.jsonl is no longer dangling (points at a real file)");
        is(readlink("./lastlog.jsonl"), $log, "lastlog.jsonl now points at the NEW log, not the deleted old one");
        1;
    };
    my $err = $@;
    chdir($start) or die "chdir back: $!";
    ok($ok, "dangling-lastlog subtest ran to completion") or diag($err);
};

subtest maybe_lastlog_repoints_over_stale_link => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/2026-run.sqlite";
    open(my $fh, '>', $log) or die "open $log: $!";  # the dated log itself exists
    close($fh);

    my $link = "$dir/lastlog.sqlite";
    symlink("$dir/deleted-old.sqlite", $link) or die "symlink setup: $!";

    my $warnings = warnings { App::Yath2::Options::Logger::_maybe_lastlog(undef, $log) };
    is($warnings, [], "no warnings re-pointing lastlog.sqlite over a dangling link");
    ok(-l $link, "lastlog.sqlite is a symlink");
    is(readlink($link), $log, "lastlog.sqlite points at the dated log, not the deleted old one");
};

done_testing;

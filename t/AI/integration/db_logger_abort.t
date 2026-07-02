use Test2::V0;
# HARNESS-DURATION-LONG

# Ticket #131 (step 3): an END-TO-END `-L` run where one job is watchdog-aborted
# must show up in the DB as a broken/failed job whose failure is counted in the
# run's totals -- not silently dropped (run logged 'complete' with NULL verdicts).
#
# Orchestration: `yath test -L=<temp sqlite>` over one fast passing job (pass.tx)
# and one job that blocks forever (hang.tx), with the workdir PINNED (--workdir) so
# a helper process can reach runner.socket. A forked helper waits until pass.tx has
# finished AND hang.tx is running, then sends a `truncate` request (the `yath abort`
# operational event, Handlers.pm request_handler_truncate) over runner.socket. The
# runner aborts hang.tx; its collector never finalizes, so the DB logger folds the
# abort into a job_tries row (status 'broken', result 0) and counts it in runs.failed.
#
# We then open the sqlite log and assert:
#   * runs.passed == 1 (pass.tx) and runs.failed == 1 (the aborted hang.tx),
#   * the hang.tx job row folded failed=1 / passed=0,
#   * hang.tx has exactly ONE job_tries row, status 'broken', result 0.
# We do NOT assert runs.status (owned by #132: 'complete' before it lands, 'broken'
# after).
#
# NOTE: an aborted job's collector never reaches 'finalized', so the logger drains
# the full DRAIN_TIMEOUT (~30s, a documented out-of-scope latent cost) before it
# exits -- hence HARNESS-DURATION-LONG. Gated on AUTHOR_TESTING + fork + the opt-in
# DB deps.

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "Not running long author test"        unless $ENV{AUTHOR_TESTING};
skip_all "This test requires forking"          if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;
eval { require DBD::SQLite;    1 } or skip_all "DBD::SQLite not available";
eval { require DBIx::QuickORM; 1 } or skip_all "DBIx::QuickORM not available";

require DBI;
require File::Temp;

use POSIX qw/WNOHANG/;
use File::Spec ();
use Time::HiRes qw/sleep time/;

use File::Basename qw/dirname/;
use lib dirname(__FILE__) . '/../lib';

use App::Yath2::Tester qw/yath/;

require Test2::Harness2::Runner::Client;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

my $tmp     = File::Temp->newdir(CLEANUP => 1);
my $db_path = "$tmp/abort.sqlite";
my $workdir = "$tmp/wd";                      # PINNED runner workdir (mkdir'd by yath)
my $started = "$tmp/hang.started";            # hang.tx is running
my $passed  = "$tmp/pass.done";               # pass.tx has finished

# ---- helper process: wait for markers, then truncate over runner.socket ------
my $helper = fork();
die "fork failed: $!" unless defined $helper;
unless ($helper) {
    # child
    my $ok = eval {
        my $socket = File::Spec->catfile($workdir, 'runner.socket');

        # Wait until pass.tx has finished AND hang.tx is running AND the socket is
        # up -- so the abort lands ONLY on hang.tx (pass.tx's pass is preserved).
        my $deadline = time + 120;
        until (-e $started && -e $passed && -S $socket) {
            exit(0) if time > $deadline;    # give up quietly; parent will fail the assert
            sleep 0.1;
        }

        # A moment to let the runner settle the dispatched job before the abort.
        sleep 0.25;

        my $client = Test2::Harness2::Runner::Client->new(workdir => $workdir);
        $client->truncate;
        1;
    };
    # Record any error for the parent's diagnostics, then exit the child.
    unless ($ok) {
        if (open(my $efh, '>', "$tmp/helper.err")) { print $efh $@; close($efh) }
    }
    exit(0);
}

# ---- the run -----------------------------------------------------------------
yath(
    command => 'test',
    args    => [
        "$dir/hang.tx",
        "$dir/pass.tx",
        '--ext=tx',
        '-j2',                         # both dispatch concurrently
        "--workdir=$workdir",          # pin the workdir so the helper finds the socket
        "-L=$db_path",
    ],
    env => {
        T2H131_STARTED   => $started,
        T2H131_PASS_DONE => $passed,
    },
    exit => T(),                       # the aborted job makes the run fail
    test => sub {
        my $out = shift;

        # Reap the helper (it has done its job by the time the run returns).
        waitpid($helper, 0);
        $helper = undef;

        if (-f "$tmp/helper.err") {
            my $e = do { open(my $h, '<', "$tmp/helper.err"); local $/; <$h> };
            diag("truncate helper error: $e");
        }

        ok(-f $db_path, "DB logger created the sqlite log file")
            or diag("output:\n$out->{output}");
        return unless -f $db_path;

        my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", '', '',
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});

        # ---- runs: the aborted job is counted, not dropped ------------------
        my $run = $dbh->selectrow_hashref("SELECT status, passed, failed FROM runs");
        ok($run, "a runs row was written") or diag("output:\n$out->{output}");
        is($run->{passed}, 1, "runs.passed == 1 (pass.tx)");
        is($run->{failed}, 1, "runs.failed == 1 (the aborted hang.tx, folded)");

        # ---- jobs: hang.tx folded failed ------------------------------------
        my $jobs = $dbh->selectall_arrayref(
            "SELECT j.job_uuid, j.passed, j.failed, tf.filename
               FROM jobs j JOIN test_files tf ON tf.test_file_id = j.test_file_id",
            {Slice => {}},
        );
        my %by_file = map { ($_->{filename} =~ m{([^/]+)$})[0] => $_ } @$jobs;

        ok($by_file{'hang.tx'}, "hang.tx job row present");
        ok($by_file{'pass.tx'}, "pass.tx job row present");

        is($by_file{'hang.tx'}{failed}, 1, "aborted hang.tx folded failed=1");
        is($by_file{'hang.tx'}{passed}, 0, "aborted hang.tx passed=0");
        is($by_file{'pass.tx'}{passed}, 1, "pass.tx passed=1");

        # ---- job_tries: hang.tx has one broken/0 try ------------------------
        my $tries = $dbh->selectall_arrayref(
            "SELECT t.try_ord, t.status, t.result
               FROM job_tries t
               JOIN jobs j ON j.job_uuid = t.job_uuid
              WHERE j.job_uuid = ?",
            {Slice => {}},
            $by_file{'hang.tx'}{job_uuid},
        );
        is(scalar(@$tries), 1, "aborted hang.tx has exactly one job_tries row");
        is($tries->[0]{status}, 'broken', "the aborted try is status 'broken'");
        is($tries->[0]{result}, 0,        "the aborted try result is 0 (aborted == failed)");

        $dbh->disconnect;
    },
);

# Safety net: reap the helper if the run's test sub did not run.
if (defined $helper) {
    kill('TERM', $helper) if kill(0, $helper);
    waitpid($helper, 0);
}

done_testing;

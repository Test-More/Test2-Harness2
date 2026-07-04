use Test2::V0;
# HARNESS-DURATION-LONG

# Integration test for the standalone DB logger process (ticket TODO-50, spec §7).
#
# Runs a tiny passing+failing suite under `yath test -L=<temp sqlite>`. The
# command forks one App::Yath2::DB::Logger BEFORE queueing the run (harness ->
# logger -> queue), which subscribes to the runner's transitions, folds them into
# run/job/job_try ROW STATE (no transitions table -- R6), and stores each
# collector's events.jsonl.zst whole as an `artifacts` blob.
#
# We then open the resulting sqlite DB and assert:
#   * the `runs` row exists with its folded counters + a 'complete' status,
#   * one `jobs` row per test file with a folded passed/failed verdict,
#   * `job_tries` rows carry the verdict columns (result tri-state, counts,
#     subtest split, exit_code) from the auditor final_state,
#   * an `events.jsonl.zst` artifact blob was written (data populated).
#
# A temp sqlite file (DBD::SQLite) -- no external server needed. The whole test is
# SKIPPED cleanly when the optional DB deps are missing (the DB layer is opt-in,
# spec R11).

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

# Opt-in DB deps: the logger lazily requires these; skip the whole test if absent.
eval { require DBD::SQLite;     1 } or skip_all "DBD::SQLite not available";
eval { require DBIx::QuickORM;  1 } or skip_all "DBIx::QuickORM not available";

require DBI;
require File::Temp;

use File::Basename qw/dirname/;
use lib dirname(__FILE__) . '/../lib';

use App::Yath2::Tester qw/yath/;
use App::Yath2::Test::DBMatrix qw/for_each_db_set/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# A dedicated sqlite log file for the run.
my $tmp     = File::Temp->newdir(CLEANUP => 1);
my $db_path = "$tmp/db_logger_test.sqlite";

# Run a passing + a failing test under the DB logger. The run exits non-zero
# (one test fails), which is expected; what we assert is what the logger wrote.
yath(
    command => 'test',
    args    => [
        "$dir/aaa_pass.tx",
        "$dir/bbb_fail.tx",
        '--ext=tx',
        "-L=$db_path",
    ],
    exit => T(),    # the failing test makes the run fail
    test => sub {
        my $out = shift;

        ok(-f $db_path, "DB logger created the sqlite log file")
            or diag("output:\n$out->{output}");

        return unless -f $db_path;

        my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", '', '',
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});

        # ---- runs ----------------------------------------------------------
        my $runs = $dbh->selectall_arrayref(
            "SELECT run_uuid_string, status, passed, failed FROM runs",
            {Slice => {}},
        );
        is(scalar(@$runs), 1, "exactly one runs row written");

        my $run = $runs->[0];
        like($run->{run_uuid_string}, qr/^[0-9a-f-]{36}$/, "run_uuid_string is the lowercase canonical form");
        is($run->{status}, 'complete', "run status folded to 'complete'");
        ok(defined($run->{passed}), "run passed counter populated (folded over resolved jobs)");
        ok(defined($run->{failed}), "run failed counter populated");
        is($run->{passed} + $run->{failed}, 2, "run counters cover both jobs (1 pass + 1 fail)");
        is($run->{passed}, 1, "exactly one job passed");
        is($run->{failed}, 1, "exactly one job failed");

        # ---- jobs ----------------------------------------------------------
        my $jobs = $dbh->selectall_arrayref(
            "SELECT j.job_uuid_string, j.passed, j.failed, tf.filename
               FROM jobs j JOIN test_files tf ON tf.test_file_id = j.test_file_id",
            {Slice => {}},
        );
        is(scalar(@$jobs), 2, "one jobs row per test file");

        my %by_file = map { ($_->{filename} =~ m{([^/]+)$})[0] => $_ } @$jobs;
        ok($by_file{'aaa_pass.tx'}, "passing job row present");
        ok($by_file{'bbb_fail.tx'}, "failing job row present");

        is($by_file{'aaa_pass.tx'}{passed}, 1, "passing job folded passed=1 (any-try-passed)");
        is($by_file{'bbb_fail.tx'}{failed}, 1, "failing job folded failed=1 (resolved && !passed)");

        # ---- job_tries (verdict columns) -----------------------------------
        my $tries = $dbh->selectall_arrayref(
            "SELECT t.try_ord, t.result, t.assertion_count, t.pass_count, t.fail_count,
                    t.subtests, t.subtests_passed, t.subtests_failed, t.exit_code,
                    tf.filename
               FROM job_tries t
               JOIN jobs j ON j.job_uuid = t.job_uuid
               JOIN test_files tf ON tf.test_file_id = j.test_file_id",
            {Slice => {}},
        );
        ok(scalar(@$tries) >= 2, "at least one job_tries row per job");

        my %try_by_file;
        for my $t (@$tries) {
            my ($base) = $t->{filename} =~ m{([^/]+)$};
            $try_by_file{$base} //= $t;
        }

        my $pass_try = $try_by_file{'aaa_pass.tx'};
        my $fail_try = $try_by_file{'bbb_fail.tx'};

        ok($pass_try, "passing try row present");
        ok($fail_try, "failing try row present");

        is($pass_try->{result}, 1, "passing try result tri-state = pass (1)");
        is($fail_try->{result}, 0, "failing try result tri-state = fail (0)");

        is($pass_try->{try_ord}, 1, "try_ord is 1-based (R10)");

        ok(defined($pass_try->{assertion_count}), "assertion_count folded from final_state");
        ok($pass_try->{pass_count} >= 1, "pass_count folded (>=1 for the passing try)");
        ok($fail_try->{fail_count} >= 1, "fail_count folded (>=1 for the failing try)");

        is($pass_try->{exit_code}, 0,  "passing try exit_code 0");
        ok($fail_try->{exit_code} != 0 || $fail_try->{fail_count} >= 1, "failing try recorded a failure (exit or count)");

        # The passing test has one top-level subtest that passes.
        ok($pass_try->{subtests} >= 1,        "passing try recorded its top-level subtest(s)");
        ok($pass_try->{subtests_passed} >= 1, "passing try subtests_passed split populated");

        # ---- artifacts (events blob) ---------------------------------------
        my $arts = $dbh->selectall_arrayref(
            "SELECT filename, length(data) AS dlen, local_path FROM artifacts WHERE filename LIKE '%events%'",
            {Slice => {}},
        );
        ok(scalar(@$arts) >= 2, "an events artifact blob per finalized collector");

        my $with_data = grep { defined($_->{dlen}) && $_->{dlen} > 0 } @$arts;
        ok($with_data >= 2, "events artifact blobs carry their data (canonical blob stored)");

        for my $a (@$arts) {
            like($a->{filename}, qr/events.*\.zst$/, "artifact filename carries the events.jsonl.zst kind");
            ok(defined($a->{local_path}), "artifact records its host-local path");
        }

        $dbh->disconnect;
    },
);

# ===========================================================================
# Server matrix (TODO-63): run the same suite under `yath test -L=<server DSN>` for
# EACH installed (flavor, version) and assert the logger wrote run/job/job_try/
# collector/artifact rows. The forked logger connects to the ephemeral QuickDB
# server by DSN; assertions read back through the provision's QuickORM connection
# (engine-agnostic). AUTHOR_TESTING gates server spin-up; the sqlite end-to-end
# above already covers the default path.
# ===========================================================================
for_each_db_set(sub {
    my ($set, $prov) = @_;
    my $label = $set->{name};
    my $con   = $prov->{con};

    yath(
        command => 'test',
        args    => ["$dir/aaa_pass.tx", "$dir/bbb_fail.tx", '--ext=tx', "-L=$prov->{dsn}"],
        exit    => T(),    # the failing test makes the run fail; expected
        test    => sub {
            my $out = shift;

            my @runs = $con->handle('runs')->all;
            is(scalar(@runs), 1, "[$label] exactly one run logged")
                or diag("output:\n$out->{output}");
            return unless @runs;

            my $run = $runs[0];
            is($run->field('status'), 'complete', "[$label] run status folded to complete");
            is($run->field('passed'), 1, "[$label] one job passed (folded)");
            is($run->field('failed'), 1, "[$label] one job failed (folded)");

            my @jobs = $con->handle('jobs')->all;
            is(scalar(@jobs), 2, "[$label] one jobs row per test file");

            my @tries = $con->handle('job_tries')->all;
            ok(scalar(@tries) >= 2, "[$label] a job_tries row per job");
            my @resolved = grep { defined($_->field('result')) } @tries;
            ok((grep {  $_->field('result') } @resolved), "[$label] a passing try (result true) recorded");
            ok((grep { !$_->field('result') } @resolved), "[$label] a failing try (result false) recorded");

            my @cols = $con->handle('collectors')->all;
            ok(scalar(@cols) >= 2, "[$label] a collectors row per finalized collector");

            my @arts = $con->handle('artifacts')->all;
            ok(scalar(@arts) >= 2, "[$label] an events artifact blob per finalized collector");
            my $with_data = grep { defined($_->field('data')) && length($_->field('data')) } @arts;
            ok($with_data >= 2, "[$label] events artifact blobs carry their data");
        },
    );
}, servers_only => 1);

done_testing;

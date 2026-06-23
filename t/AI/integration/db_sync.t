use Test2::V0;
# HARNESS-DURATION-LONG

# Integration test for the DB->DB sync engine + the `yath db sync` and top-level
# `import` commands (tickets #53 / #54, spec §8).
#
# Flow (sqlite -> sqlite, DBD::SQLite only -- no external server):
#   1. Populate a SOURCE sqlite DB by running a tiny pass+fail suite under the
#      #50 DB logger (`yath test -L=<source.sqlite>`). This gives us a real run
#      with jobs / job_tries / artifacts + the natural-key entities (hosts,
#      machine_users, projects, test_files) the logger created.
#   2. PRE-SEED the destination sqlite DB with UNRELATED natural-key rows so its
#      auto-increment ids are OFFSET from the source's. This is what makes the
#      FK-remap (R5) observable: a run synced verbatim-by-integer would point at
#      the wrong dest entity; a correctly-remapped run resolves by NATURAL KEY.
#   3. Sync via the App::Yath2::DB::Sync engine directly, and (separately) via the
#      `yath db sync` command end-to-end. Assert the run-data rows arrived with
#      verbatim UUID PKs and the natural-key FKs remapped to the dest entities.
#   4. Re-sync -> idempotent (skipped, no duplicates).
#   5. `import` auto-selects the single run from the source log file (no run_uuid)
#      -- sharing the same source fixture.
#   6. The --as-user override attributes submitted_by to the importing user.
#
# SKIPPED cleanly when the optional DB deps are absent (the DB layer is opt-in,
# spec R11).

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

eval { require DBD::SQLite;    1 } or skip_all "DBD::SQLite not available";
eval { require DBIx::QuickORM; 1 } or skip_all "DBIx::QuickORM not available";

require DBI;
require File::Temp;

use App::Yath2::Tester qw/yath/;

require App::Yath2::DB::Connect;
require App::Yath2::Schema;
require App::Yath2::DB::Sync;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# ---------------------------------------------------------------------------
# Build the SOURCE database: run a pass+fail suite under the DB logger.
# ---------------------------------------------------------------------------
my $tmp     = File::Temp->newdir(CLEANUP => 1);
my $src_db  = "$tmp/source.sqlite";

yath(
    command => 'test',
    args    => [
        "$dir/aaa_pass.tx",
        "$dir/bbb_fail.tx",
        '--ext=tx',
        "-L=$src_db",
    ],
    exit => T(),    # the failing test makes the run fail; expected
    test => sub {
        my $out = shift;
        ok(-f $src_db, "DB logger created the source sqlite DB")
            or diag("output:\n$out->{output}");
    },
);

skip_all "source DB was not created" unless -f $src_db;

# Raw-DBI helper (read-only assertions, independent of QuickORM).
sub raw {
    my ($path) = @_;
    return DBI->connect("dbi:SQLite:dbname=$path", '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}

# Snapshot the source's run-data for cross-checks.
my $src_dbh = raw($src_db);
my $src_run = $src_dbh->selectrow_hashref("SELECT run_uuid_string, status FROM runs");
ok($src_run, "source has a run row");
my $src_run_uuid = $src_run->{run_uuid_string};
like($src_run_uuid, qr/^[0-9a-f-]{36}$/, "source run_uuid_string is canonical lowercase");

my ($src_njobs) = $src_dbh->selectrow_array("SELECT COUNT(*) FROM jobs");
my ($src_ntries) = $src_dbh->selectrow_array("SELECT COUNT(*) FROM job_tries");
my ($src_narts)  = $src_dbh->selectrow_array("SELECT COUNT(*) FROM artifacts");
ok($src_njobs >= 2, "source has >= 2 jobs (one per test file)");
ok($src_ntries >= 2, "source has >= 2 job_tries");
ok($src_narts >= 1, "source has >= 1 artifact (events blob)");

# The source's natural-key entities (by natural key) we expect to arrive on dest.
my $src_hosts = $src_dbh->selectall_arrayref("SELECT hostname FROM hosts", {Slice => {}});
my $src_projs = $src_dbh->selectall_arrayref("SELECT name FROM projects", {Slice => {}});
my $src_files = $src_dbh->selectall_arrayref("SELECT filename FROM test_files", {Slice => {}});
$src_dbh->disconnect;

# ---------------------------------------------------------------------------
# Helper: a fresh DESTINATION sqlite DB, PRE-SEEDED with unrelated natural-key
# rows so its auto-increment ids are OFFSET from the source's. This forces the
# FK-remap to be observable (verbatim integer copy would mis-point).
# ---------------------------------------------------------------------------
my $dest_seq = 0;
sub fresh_dest {
    my $path = "$tmp/dest_" . (++$dest_seq) . ".sqlite";

    # Bootstrap the schema (build_connection does this for a fresh sqlite file).
    my $flavor = App::Yath2::DB::Flavor->by_name('sqlite');
    App::Yath2::DB::Connect::ensure_sqlite_db($path, $flavor);

    # Pre-seed offset rows so dest ids != source ids for the same natural key.
    my $dbh = raw($path);
    $dbh->do("INSERT INTO hosts (hostname) VALUES ('zzz-unrelated-host-1')");
    $dbh->do("INSERT INTO hosts (hostname) VALUES ('zzz-unrelated-host-2')");
    $dbh->do("INSERT INTO projects (name) VALUES ('zzz-unrelated-project')");
    $dbh->do("INSERT INTO projects (name) VALUES ('zzz-unrelated-project-2')");
    $dbh->do("INSERT INTO projects (name) VALUES ('zzz-unrelated-project-3')");
    $dbh->do("INSERT INTO test_files (filename) VALUES ('zzz/unrelated/file.t')");
    $dbh->disconnect;

    return $path;
}

# build a QuickORM connection for a sqlite path.
sub con_for {
    my ($path) = @_;
    my ($con) = App::Yath2::DB::Connect::build_connection($path);
    return $con;
}

# Cross-DB assertion: the synced run arrived, UUID PK verbatim, natural-key FKs
# remapped to the DEST entities (resolved by natural key, NOT by source integer).
sub assert_synced {
    my ($dest_db, %opts) = @_;
    my $label = $opts{label} // 'sync';

    my $dbh = raw($dest_db);

    # ---- runs: verbatim uuid, status carried ----
    my $runs = $dbh->selectall_arrayref(
        "SELECT run_uuid_string, status, passed, failed FROM runs", {Slice => {}});
    is(scalar(@$runs), 1, "[$label] exactly one run synced");
    my $run = $runs->[0];
    is($run->{run_uuid_string}, $src_run_uuid, "[$label] run_uuid copied verbatim (UUID PK, no remap)");
    is($run->{status}, $src_run->{status}, "[$label] run status carried");

    # ---- FK remap: the run's host/project resolve to the dest entity that
    #      carries the SOURCE natural key, and that dest id is OFFSET past the
    #      pre-seeded rows (so a verbatim integer copy would have mis-pointed). ----
    my $run_fks = $dbh->selectrow_hashref(
        "SELECT h.hostname, p.name AS project_name, mu.username AS ran_by_user
           FROM runs r
           JOIN hosts h         ON h.host_id = r.host_id
           JOIN projects p      ON p.project_id = r.project_id
           JOIN machine_users mu ON mu.machine_user_id = r.ran_by");
    ok($run_fks, "[$label] run FKs all resolve on the dest");
    is($run_fks->{hostname}, $src_hosts->[0]{hostname}, "[$label] runs.host_id remapped to the source hostname (R5)")
        if @$src_hosts;
    is($run_fks->{project_name}, $src_projs->[0]{name}, "[$label] runs.project_id remapped to the source project name (R5)")
        if @$src_projs;
    ok(defined($run_fks->{ran_by_user}) && length($run_fks->{ran_by_user}),
        "[$label] runs.ran_by remapped to a machine_user (host+username, R5)");

    # The dest host id for the synced run must be GREATER than the pre-seeded
    # rows' ids (proving it was created/resolved by natural key, not copied).
    my ($run_host_id) = $dbh->selectrow_array("SELECT host_id FROM runs");
    ok($run_host_id >= 3, "[$label] run host_id is past the pre-seeded offset (remap created/resolved a new id)");

    # ---- jobs: count + test_file remap ----
    my $jobs = $dbh->selectall_arrayref(
        "SELECT j.job_uuid_string, j.passed, j.failed, tf.filename
           FROM jobs j JOIN test_files tf ON tf.test_file_id = j.test_file_id",
        {Slice => {}});
    is(scalar(@$jobs), $src_njobs, "[$label] all jobs synced");
    my %by_file = map { ($_->{filename} =~ m{([^/]+)$})[0] => $_ } @$jobs;
    ok($by_file{'aaa_pass.tx'}, "[$label] passing job present (test_file remapped by filename)");
    ok($by_file{'bbb_fail.tx'}, "[$label] failing job present");

    # ---- job_tries: verbatim derived uuid PKs + verdict columns ----
    my ($ntries) = $dbh->selectrow_array("SELECT COUNT(*) FROM job_tries");
    is($ntries, $src_ntries, "[$label] all job_tries synced");
    my $tries = $dbh->selectall_arrayref(
        "SELECT result, pass_count, fail_count, try_ord FROM job_tries WHERE result IS NOT NULL",
        {Slice => {}});
    ok(scalar(@$tries) >= 1, "[$label] resolved job_tries carry their verdict columns");
    ok((grep { $_->{result} == 1 } @$tries), "[$label] a passing try (result=1) arrived");
    ok((grep { $_->{result} == 0 } @$tries), "[$label] a failing try (result=0) arrived");

    # ---- artifacts: data blob copied, local_path NOT copied (host-local, §5) ----
    my $arts = $dbh->selectall_arrayref(
        "SELECT filename, length(data) AS dlen, local_path FROM artifacts", {Slice => {}});
    is(scalar(@$arts), $src_narts, "[$label] all artifacts synced");
    my $with_data = grep { defined($_->{dlen}) && $_->{dlen} > 0 } @$arts;
    ok($with_data >= 1, "[$label] artifact data blob copied");
    my $with_localpath = grep { defined($_->{local_path}) } @$arts;
    is($with_localpath, 0, "[$label] artifact local_path NOT copied (host-local, skipped)");

    $dbh->disconnect;
}

# ===========================================================================
# 1. Engine-direct sync (App::Yath2::DB::Sync), carry-original attribution.
# ===========================================================================
subtest engine_run_delta => sub {
    my $dest_db = fresh_dest();

    my $sync = App::Yath2::DB::Sync->new(
        source => con_for($src_db),
        dest   => con_for($dest_db),
    );

    my @delta = $sync->run_delta;
    is(scalar(@delta), 1, "run_delta finds the one source run missing in dest");
    is(lc($delta[0]), $src_run_uuid, "run_delta returns the source run_uuid");

    my $stats = $sync->sync_runs(\@delta);
    is($stats->{runs}, 1, "engine reports 1 run synced");
    is($stats->{jobs}, $src_njobs, "engine reports all jobs synced");
    is($stats->{job_tries}, $src_ntries, "engine reports all job_tries synced");
    is($stats->{artifacts}, $src_narts, "engine reports all artifacts synced");

    assert_synced($dest_db, label => 'engine');

    # ---- idempotency: re-sync is a no-op (skipped, no duplicates) ----
    my $sync2 = App::Yath2::DB::Sync->new(
        source => con_for($src_db),
        dest   => con_for($dest_db),
    );
    is(scalar($sync2->run_delta), 0, "after sync, run_delta is empty (idempotent selection)");

    my $stats2 = $sync2->sync_run($src_run_uuid);
    is($stats2->{skipped_runs}, 1, "re-syncing the same run is skipped");
    is($stats2->{runs}, 0, "re-sync writes no new run");

    my $dbh = raw($dest_db);
    my ($n) = $dbh->selectrow_array("SELECT COUNT(*) FROM runs");
    is($n, 1, "still exactly one run after re-sync (no duplicate)");
    $dbh->disconnect;
};

# ===========================================================================
# 2. `yath db sync` end-to-end (command + option parsing).
# ===========================================================================
subtest command_db_sync => sub {
    my $dest_db = fresh_dest();

    yath(
        command => 'db',
        args    => ['sync', "--from=$src_db", "--to=$dest_db"],
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/Syncing 1 run/, "command reports syncing 1 run")
                or diag("output:\n$out->{output}");
        },
    );

    assert_synced($dest_db, label => 'command');

    # Re-run the command -> "nothing to sync".
    yath(
        command => 'db',
        args    => ['sync', "--from=$src_db", "--to=$dest_db"],
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/Nothing to sync/, "re-running db sync reports nothing to do");
        },
    );
};

# ===========================================================================
# 3. submitted_by override attribution (--as-user).
# ===========================================================================
subtest as_user_override => sub {
    my $dest_db = fresh_dest();

    my $sync = App::Yath2::DB::Sync->new(
        source  => con_for($src_db),
        dest    => con_for($dest_db),
        as_user => 'importbot',
    );
    $sync->sync_run($src_run_uuid);

    my $dbh = raw($dest_db);
    my $attr = $dbh->selectrow_hashref(
        "SELECT u.username
           FROM runs r JOIN users u ON u.user_id = r.submitted_by");
    ok($attr, "submitted_by was set under override");
    is($attr->{username}, 'importbot', "--as-user attributes submitted_by to the importing user (R7)");
    $dbh->disconnect;
};

# ===========================================================================
# 4. `import` command: auto-select the single run (no run_uuid).
# ===========================================================================
subtest import_command => sub {
    my $dest_db = fresh_dest();

    yath(
        command => 'import',
        args    => ["--to=$dest_db", '--', $src_db],
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/Importing run '\Q$src_run_uuid\E'/, "import auto-selected the single run")
                or diag("output:\n$out->{output}");
            like($out->{output}, qr/Done\. runs=1/, "import reports the run imported");
        },
    );

    assert_synced($dest_db, label => 'import');

    # Re-import is idempotent.
    yath(
        command => 'import',
        args    => ["--to=$dest_db", '--', $src_db],
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/already present/, "re-import is idempotent (already present)");
        },
    );
};

# ===========================================================================
# 5. import engine guard: only_run_uuid croaks on a multi-run source.
# ===========================================================================
subtest only_run_uuid_guard => sub {
    # Build a source with TWO runs by syncing the same run under a second uuid.
    my $multi = "$tmp/multi.sqlite";
    my $flavor = App::Yath2::DB::Flavor->by_name('sqlite');
    App::Yath2::DB::Connect::ensure_sqlite_db($multi, $flavor);

    # Copy the real run in, then clone its run row under a new uuid so the file
    # holds two runs (we only need the runs table populated for the guard).
    my $sync = App::Yath2::DB::Sync->new(source => con_for($src_db), dest => con_for($multi));
    $sync->sync_run($src_run_uuid);

    my $dbh = raw($multi);
    # Duplicate the run row under a different uuid (16 zero-ish bytes -> a 2nd run).
    $dbh->do(
        "INSERT INTO runs (run_uuid, project_id, host_id, ran_by, status, version)
         SELECT X'00112233445566778899aabbccddeeff', project_id, host_id, ran_by, status, version
           FROM runs LIMIT 1");
    my ($n) = $dbh->selectrow_array("SELECT COUNT(*) FROM runs");
    is($n, 2, "multi-run source has 2 runs");
    $dbh->disconnect;

    my $isync = App::Yath2::DB::Sync->new(source => con_for($multi), dest => con_for(fresh_dest()));
    my $ok = eval { $isync->only_run_uuid; 1 };
    my $err = $@;
    ok(!$ok, "only_run_uuid croaks on a multi-run source (import auto-select)");
    like($err, qr/2 runs/, "the error names the run count");
};

done_testing;

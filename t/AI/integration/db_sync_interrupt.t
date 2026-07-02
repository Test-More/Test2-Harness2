use Test2::V0;
# HARNESS-DURATION-LONG

# Regression test for #129: `yath db sync` is not transactional -- an interrupted
# sync (Ctrl-C, network drop, a constraint error on one artifact) after the runs
# row was inserted but before jobs/tries/collectors/artifacts finished used to
# leave the destination PERMANENTLY incomplete: the run-level short-circuit skipped
# it on every future sync, and `run_delta` (which excludes ANY dest-present run
# regardless of status) never re-selected it either.
#
# The fix (App::Yath2::DB::Sync):
#   * wraps each per-run copy in a single TOP-LEVEL destination transaction, so an
#     interrupted sync rolls back to NO trace on the dest -- run_delta then
#     re-selects the run naturally (this is what actually closes the headline bug);
#   * drops the run-level short-circuit and ALWAYS descends into the four child
#     syncs (relying on their per-UUID exists-checks), so an explicit `--run-uuid`
#     repairs a legacy pre-fix partial; a present runs row only skips the runs-row
#     INSERT (counted in skipped_runs);
#   * on rollback, restores the in-memory stats counters and clears the
#     natural-key PK cache (its dest PKs were rolled back).
#
# This test drives the App::Yath2::DB::Sync engine directly (fault injection via a
# `local`-overridden child sync that dies) across the #63 DBMatrix -- a fixed
# sqlite SOURCE into each (flavor, version) DEST cell, including duckdb (whose
# dialect issues the txn via raw BEGIN/COMMIT/ROLLBACK) and, under AUTHOR_TESTING,
# every server flavor.
#
# SKIPPED cleanly when the optional DB deps are absent (the DB layer is opt-in).

eval { require DBD::SQLite;    1 } or skip_all "DBD::SQLite not available";
eval { require DBIx::QuickORM; 1 } or skip_all "DBIx::QuickORM not available";

require File::Temp;

use File::Basename qw/dirname/;
use lib dirname(__FILE__) . '/../lib';

use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;
use App::Yath2::Test::DBMatrix qw/for_each_db_set/;

require App::Yath2::DB::Connect;
require App::Yath2::Schema;    # installs qorm() + the autorow namespace
require App::Yath2::DB::Sync;

# ---------------------------------------------------------------------------
# Build the fixed sqlite SOURCE once: three complete, terminal runs.
#   * run1 -- the interrupted run (fault-injection target).
#   * run2 -- SHARES run1's natural-key source rows (same source ids), so reusing
#             the faulted Sync object on it proves the rolled-back PK cache was
#             cleared (a stale cache would point at a rolled-back dest PK -> a
#             dangling FK -> insert dies).
#   * run3 -- its own entities; used to simulate a LEGACY pre-fix partial on the
#             dest (a runs row + a job, missing tries/collectors/artifacts).
# The source is written once and only READ by the cells (Sync never writes the
# source), so it is safe to share across the forked server cells.
# ---------------------------------------------------------------------------
my $tmp      = File::Temp->newdir(CLEANUP => 1);
my $src_path = "$tmp/source.sqlite";

my ($R1, $R2, $R3);
{
    my ($scon) = App::Yath2::DB::Connect::build_connection($src_path);

    # Shared natural-key entities for run1 + run2 (same SOURCE ids -> same cache key).
    my $shost = $scon->handle('hosts')->insert({hostname => 'shared.host'});
    my $sproj = $scon->handle('projects')->insert({name => 'shared.proj'});
    my $smu   = $scon->handle('machine_users')->insert({host_id => $shost->field('host_id'), username => 'osuser'});
    my $stf   = $scon->handle('test_files')->insert({project_id => $sproj->field('project_id'), filename => 't/shared.t'});

    # run3's own entities.
    my $host3 = $scon->handle('hosts')->insert({hostname => 'r3.host'});
    my $proj3 = $scon->handle('projects')->insert({name => 'r3.proj'});
    my $mu3   = $scon->handle('machine_users')->insert({host_id => $host3->field('host_id'), username => 'osuser'});
    my $tf3   = $scon->handle('test_files')->insert({project_id => $proj3->field('project_id'), filename => 't/r3.t'});

    $R1 = add_run($scon, $shost, $sproj, $smu, $stf);
    $R2 = add_run($scon, $shost, $sproj, $smu, $stf);
    $R3 = add_run($scon, $host3, $proj3, $mu3, $tf3);
}

# Insert one complete, terminal run (1 job / 1 try / 1 collector / 1 artifact)
# referencing the given natural-key entity rows. Returns {run_uuid, job_uuid}
# (lowercased, for the QuickORM lowercase-uuid storage convention).
sub add_run {
    my ($con, $host, $proj, $mu, $tf) = @_;

    my $run_uuid = gen_uuid();
    $con->handle('runs')->insert({
        run_uuid   => $run_uuid,
        project_id => $proj->field('project_id'),
        host_id    => $host->field('host_id'),
        ran_by     => $mu->field('machine_user_id'),
        status     => 'complete',
        passed     => 1,
        failed     => 0,
    });

    my $job_uuid = gen_uuid();
    $con->handle('jobs')->insert({
        job_uuid     => $job_uuid,
        run_uuid     => $run_uuid,
        test_file_id => $tf->field('test_file_id'),
        passed       => 1,
        failed       => 0,
    });

    my $try_uuid = derive_uuid($job_uuid, 1);
    $con->handle('job_tries')->insert({
        job_try_uuid => $try_uuid,
        job_uuid     => $job_uuid,
        try_ord      => 1,
        result       => 1,
        status       => 'complete',
    });

    my $col_uuid = gen_uuid();
    $con->handle('collectors')->insert({collector_uuid => $col_uuid, run_uuid => $run_uuid, job_try_uuid => $try_uuid});
    $con->handle('artifacts')->insert({
        artifact_uuid  => gen_uuid(),
        run_uuid       => $run_uuid,
        collector_uuid => $col_uuid,
        filename       => 'events.jsonl.zst',
        data           => "\x00\x01\x02zst",
    });

    return {run_uuid => lc($run_uuid), job_uuid => lc($job_uuid)};
}

sub con_for {
    my ($path) = @_;
    my ($con) = App::Yath2::DB::Connect::build_connection($path);
    return $con;
}

# Per-run child row counts on a destination (engine-agnostic via QuickORM handles;
# job_tries carries no run_uuid, so it is keyed by job_uuid).
sub count_run {
    my ($con, $R) = @_;
    my @runs  = $con->handle('runs',       where => {run_uuid => $R->{run_uuid}})->all;
    my @jobs  = $con->handle('jobs',       where => {run_uuid => $R->{run_uuid}})->all;
    my @tries = $con->handle('job_tries',  where => {job_uuid => $R->{job_uuid}})->all;
    my @cols  = $con->handle('collectors', where => {run_uuid => $R->{run_uuid}})->all;
    my @arts  = $con->handle('artifacts',  where => {run_uuid => $R->{run_uuid}})->all;
    return {
        runs => scalar(@runs), jobs => scalar(@jobs), job_tries => scalar(@tries),
        collectors => scalar(@cols), artifacts => scalar(@arts),
    };
}

sub assert_run_complete {
    my ($con, $R, $label, $phase) = @_;
    is(
        count_run($con, $R),
        {runs => 1, jobs => 1, job_tries => 1, collectors => 1, artifacts => 1},
        "[$label] ($phase) run is complete on the dest (all child rows present)",
    );
}

# ===========================================================================
# Drive the whole interrupt/recover/idempotency/repair sequence per matrix cell.
# The cell's provisioned connection is the DEST; the sqlite fixture is the SOURCE.
# ===========================================================================
for_each_db_set(sub {
    my ($set, $prov) = @_;
    my $dest  = $prov->{con};
    my $label = $set->{name};
    my $scon  = con_for($src_path);

    # -- (a) FAULT INJECTION: kill a sync after the runs-row insert. ----------
    my $s1 = App::Yath2::DB::Sync->new(source => $scon, dest => $dest);
    {
        no warnings 'redefine';
        local *App::Yath2::DB::Sync::_sync_collectors = sub { die "boom\n" };
        my $ok  = eval { $s1->sync_run($R1->{run_uuid}); 1 };
        my $err = $@;
        ok(!$ok, "[$label] (a) an interrupted sync dies");
        like($err, qr/boom/, "[$label] (a) the injected fault propagated (die-on-error preserved)");
    }
    ok(!$dest->handle('runs', where => {run_uuid => $R1->{run_uuid}})->first,
        "[$label] (a) ROLLBACK: no runs row for the interrupted run on the dest");
    ok(!$dest->handle('jobs', where => {run_uuid => $R1->{run_uuid}})->first,
        "[$label] (a) ROLLBACK: no jobs rows either (whole per-run txn rolled back)");
    is($s1->stats->{runs}, 0, "[$label] (a) rolled-back rows are NOT counted (stats restored)");
    is($s1->stats->{skipped_runs}, 0, "[$label] (a) no phantom skipped_runs");
    my %delta_after_a = map { ($_ => 1) } $s1->run_delta;
    ok($delta_after_a{$R1->{run_uuid}}, "[$label] (a) run_delta STILL lists the interrupted run (no permanent skip)");

    # -- (e) CACHE/STATS HYGIENE: reuse the SAME faulted object for run2. ------
    #    run2 shares run1's source entities, so a stale (un-cleared) PK cache
    #    would point at rolled-back dest rows -> a dangling FK -> the insert dies.
    my $ok_e  = eval { $s1->sync_run($R2->{run_uuid}); 1 };
    my $err_e = $@;
    ok($ok_e, "[$label] (e) reusing the faulted Sync object for a different run succeeds (cache was cleared)")
        or diag("reuse failed: $err_e");
    is($s1->stats->{runs}, 1, "[$label] (e) stats show exactly run2 (no phantom from the rolled-back run1)");
    is($s1->stats->{skipped_runs}, 0, "[$label] (e) still no phantom skipped_runs");
    my $run2 = $dest->handle('runs', where => {run_uuid => $R2->{run_uuid}})->first;
    ok($run2, "[$label] (e) run2 landed on the dest");
    ok($run2 && $dest->handle('hosts', where => {host_id => $run2->field('host_id')})->first,
        "[$label] (e) run2's host FK resolves on the dest (no dangling PK from a stale cache)");

    # -- LEGACY-PARTIAL SETUP: hand-insert a pre-#129-fix partial for run3 ------
    #    (a runs row + a job, but no tries/collectors/artifacts).
    my $lh = $dest->handle('hosts')->insert({hostname => "legacy.host.$label"});
    my $lp = $dest->handle('projects')->insert({name => "legacy.proj.$label"});
    my $lm = $dest->handle('machine_users')->insert({host_id => $lh->field('host_id'), username => 'osuser'});
    my $lf = $dest->handle('test_files')->insert({project_id => $lp->field('project_id'), filename => 't/legacy.t'});
    $dest->handle('runs')->insert({
        run_uuid   => $R3->{run_uuid},
        project_id => $lp->field('project_id'),
        host_id    => $lh->field('host_id'),
        ran_by     => $lm->field('machine_user_id'),
        status     => 'complete',
        passed     => 1,
        failed     => 0,
    });
    $dest->handle('jobs')->insert({
        job_uuid     => $R3->{job_uuid},
        run_uuid     => $R3->{run_uuid},
        test_file_id => $lf->field('test_file_id'),
        passed       => 1,
        failed       => 0,
    });

    # -- (f)+(b) DELTA-GAP PIN + RECOVERY via the default-selection path. -------
    my $s2 = App::Yath2::DB::Sync->new(source => $scon, dest => $dest);
    my %in_delta = map { ($_ => 1) } $s2->run_delta;
    ok($in_delta{$R1->{run_uuid}},
        "[$label] (f) the default delta re-selects the interrupted run1 (fork-A-alone would MISS it -- the txn is what closes #129)");
    ok(!$in_delta{$R2->{run_uuid}}, "[$label] (f) delta excludes run2 (already complete on the dest)");
    ok(!$in_delta{$R3->{run_uuid}},
        "[$label] (f) delta EXCLUDES the dest-present legacy partial run3 (this is the any-status gap the per-run txn works around)");

    $s2->sync_runs([keys %in_delta]);    # the exact default `yath db sync` path
    is($s2->stats->{runs}, 1, "[$label] (b) the delta path synced exactly run1");
    is($s2->stats->{skipped_runs}, 0, "[$label] (b) recovery did not skip run1");
    assert_run_complete($dest, $R1, $label, "recovery");

    # -- (c) IDEMPOTENCY: a third sync of run1 copies NOTHING. -----------------
    my $before = count_run($dest, $R1);
    my $s3 = App::Yath2::DB::Sync->new(source => $scon, dest => $dest);
    $s3->sync_run($R1->{run_uuid});
    is(
        $s3->stats,
        {runs => 0, jobs => 0, job_tries => 0, collectors => 0, artifacts => 0, skipped_runs => 1},
        "[$label] (c) idempotent third sync copies nothing (only skipped_runs=1)",
    );
    is(count_run($dest, $R1), $before, "[$label] (c) the dest row counts are unchanged");

    # -- (d) LEGACY-PARTIAL REPAIR via an explicit run-uuid (fork-A path). ------
    my $s4 = App::Yath2::DB::Sync->new(source => $scon, dest => $dest);
    $s4->sync_run($R3->{run_uuid});
    is($s4->stats->{skipped_runs}, 1, "[$label] (d) run3's runs row already present -> skipped_runs (runs-row insert skipped)");
    is($s4->stats->{jobs}, 0, "[$label] (d) run3's job already present -> jobs stat 0 (exists-check hit)");
    is($s4->stats->{job_tries}, 1, "[$label] (d) run3's missing try was filled in");
    is($s4->stats->{collectors}, 1, "[$label] (d) run3's missing collector was filled in");
    is($s4->stats->{artifacts}, 1, "[$label] (d) run3's missing artifact was filled in");
    assert_run_complete($dest, $R3, $label, "legacy-repair");
});

done_testing;

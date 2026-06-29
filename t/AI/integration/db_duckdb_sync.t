use Test2::V0;

# Cross-engine sync/import with DuckDB at one end. DuckDB is a SYNC/READ target
# (never a logger), so this is its primary coverage: the production READER path
# (build_connection(..., read_only => 1) on a .duckdb) and the App::Yath2::DB::Sync
# engine in both directions. DuckDB/log.sql carries the FULL FK set; sync is
# INSERT-ONLY (parents before children), so the FKs are always satisfiable -- this
# test pins that syncing TO a .duckdb works with the FKs in place.
#
#   * DuckDB SOURCE -> SQLite DEST -- the path `yath import x.duckdb` and
#     `yath db sync --from x.duckdb --to <sqlite>` take. A native DuckDB BOOLEAN
#     FALSE reads back as '' (empty string); the sqlite/mysql/percona dests declare
#     CHECK(col IN (0,1)) on every boolean, so without normalization the dest
#     INSERT dies "CHECK constraint failed". Sync::_row_data coerces booleans to
#     0/1/undef; this test pins that (a FALSE boolean in the source must land as 0).
#   * SQLite SOURCE -> DuckDB DEST -- the reverse, proving a .duckdb is a valid
#     sync write target (full FKs satisfied) and 0/1 booleans deflate to its
#     native BOOLEAN.
#
# SKIPPED cleanly when DBD::DuckDB / DBD::SQLite / DBIx::QuickORM are absent
# (the DB layer is opt-in, spec R11).

eval { require DBD::DuckDB;    1 } or skip_all "DBD::DuckDB not available";
eval { require DBD::SQLite;    1 } or skip_all "DBD::SQLite not available";
eval { require DBIx::QuickORM; 1 } or skip_all "DBIx::QuickORM not available";

require DBI;
require File::Temp;

use File::Basename qw/dirname/;
use lib dirname(__FILE__) . '/../lib';

use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;

require App::Yath2::DB::Connect;
require App::Yath2::Schema;
require App::Yath2::DB::Sync;

my $tmp = File::Temp->newdir(CLEANUP => 1);
my $seq = 0;

# Insert a complete run graph that includes a FALSE boolean (run.canon = 0, a
# failing job passed=0/failed=1, job_try result=0) plus a TRUE (run.pinned = 1)
# and the INTEGER counters run.passed/run.failed (which must NOT be coerced).
# Returns the run_uuid.
sub insert_run {
    my ($con) = @_;

    my $host  = $con->handle('hosts')->insert({hostname => 'host.xeng.' . ++$seq});
    my $proj  = $con->handle('projects')->insert({name => 'proj-xeng-' . $seq});
    my $muser = $con->handle('machine_users')->insert({host_id => $host->field('host_id'), username => 'osuser'});
    my $file  = $con->handle('test_files')->insert({project_id => $proj->field('project_id'), filename => 't/fail.t'});

    my $run_uuid = gen_uuid();
    $con->handle('runs')->insert({
        run_uuid   => $run_uuid,
        project_id => $proj->field('project_id'),
        host_id    => $host->field('host_id'),
        ran_by     => $muser->field('machine_user_id'),
        passed     => 3,    # INTEGER counter (NOT a boolean)
        failed     => 2,    # INTEGER counter (NOT a boolean)
        status     => 'complete',
        canon      => 0,    # FALSE boolean -- the bug trigger
        pinned     => 1,    # TRUE boolean
        # has_coverage / has_resources omitted => NULL (tri-state)
    });

    my $job_uuid = gen_uuid();
    $con->handle('jobs')->insert({
        job_uuid     => $job_uuid,
        run_uuid     => $run_uuid,
        test_file_id => $file->field('test_file_id'),
        passed       => 0,    # FALSE boolean
        failed       => 1,    # TRUE boolean
    });

    my $try_uuid = derive_uuid($job_uuid, 1);
    $con->handle('job_tries')->insert({
        job_try_uuid => $try_uuid,
        job_uuid     => $job_uuid,
        try_ord      => 1,
        result       => 0,    # FALSE boolean (failing try)
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

    return $run_uuid;
}

sub raw_sqlite { DBI->connect("dbi:SQLite:dbname=$_[0]", '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1}) }
sub raw_duckdb {
    DBI->connect("dbi:DuckDB:dbname=$_[0]", '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, duckdb_config => {access_mode => 'read_only'}, duckdb_checkpoint_on_disconnect => 0});
}

# ===========================================================================
# DuckDB SOURCE -> SQLite DEST (the import / db-sync-from-duckdb path).
# ===========================================================================
subtest duckdb_to_sqlite => sub {
    my $src_path = "$tmp/src.duckdb";
    my $dst_path = "$tmp/dst.sqlite";

    my ($src_rw) = App::Yath2::DB::Connect::build_connection($src_path);    # writer bootstraps + writes
    my $run_uuid = insert_run($src_rw);

    # Reopen the source READ-ONLY through the production reader path (what
    # import/db-sync use). The file exists, so the read_only open succeeds.
    my ($src_ro) = App::Yath2::DB::Connect::build_connection($src_path, read_only => 1);
    ok($src_ro, "opened the .duckdb source read-only via build_connection(read_only => 1)");

    my ($dst) = App::Yath2::DB::Connect::build_connection($dst_path);

    my $sync = App::Yath2::DB::Sync->new(source => $src_ro, dest => $dst);
    my $ok = eval { $sync->sync_run($run_uuid); 1 };
    ok($ok, "sync DuckDB -> sqlite succeeded (boolean FALSE normalized, no CHECK violation)")
        or diag("sync died: $@");

    # Read the dest back raw and pin the booleans + the integer counters.
    my $dbh = raw_sqlite($dst_path);
    my $run = $dbh->selectrow_hashref("SELECT canon, pinned, passed, failed, status FROM runs WHERE run_uuid_string = ?", undef, $run_uuid);
    ok($run, "run landed on the sqlite dest");
    is($run->{canon},  0, "run.canon FALSE boolean synced as 0 (not '')");
    is($run->{pinned}, 1, "run.pinned TRUE boolean synced as 1");
    is($run->{passed}, 3, "run.passed INTEGER counter preserved (NOT coerced to a boolean)");
    is($run->{failed}, 2, "run.failed INTEGER counter preserved");

    # one run / one job in this fixture (jobs carries no run_uuid_string mirror).
    my $job = $dbh->selectrow_hashref("SELECT passed, failed FROM jobs LIMIT 1");
    is($job->{passed}, 0, "job.passed FALSE boolean synced as 0");
    is($job->{failed}, 1, "job.failed TRUE boolean synced as 1");

    my ($result) = $dbh->selectrow_array("SELECT result FROM job_tries LIMIT 1");
    is($result, 0, "job_try.result FALSE boolean synced as 0");

    my ($nart) = $dbh->selectrow_array("SELECT COUNT(*) FROM artifacts");
    ok($nart >= 1, "artifact blob synced across to the sqlite dest");
    $dbh->disconnect;
};

# ===========================================================================
# SQLite SOURCE -> DuckDB DEST (the reverse: a .duckdb is a valid write target).
# ===========================================================================
subtest sqlite_to_duckdb => sub {
    my $src_path = "$tmp/src2.sqlite";
    my $dst_path = "$tmp/dst2.duckdb";

    my ($src) = App::Yath2::DB::Connect::build_connection($src_path);
    my $run_uuid = insert_run($src);

    my ($dst) = App::Yath2::DB::Connect::build_connection($dst_path);    # duckdb write target

    my $sync = App::Yath2::DB::Sync->new(source => $src, dest => $dst);
    my $ok = eval { $sync->sync_run($run_uuid); 1 };
    ok($ok, "sync sqlite -> DuckDB succeeded") or diag("sync died: $@");

    # Read the duckdb dest back read-only (after we are done writing).
    my $dbh = raw_duckdb($dst_path);
    my $run = $dbh->selectrow_hashref("SELECT canon, pinned, passed, failed FROM runs WHERE run_uuid = ?", undef, $run_uuid);
    ok($run, "run landed on the duckdb dest");
    ok(!$run->{canon},  "run.canon FALSE on the duckdb dest");
    ok($run->{pinned},  "run.pinned TRUE on the duckdb dest");
    is($run->{passed}, 3, "run.passed INTEGER counter preserved on duckdb dest");

    my ($njobs)  = $dbh->selectrow_array("SELECT COUNT(*) FROM jobs");
    my ($ntries) = $dbh->selectrow_array("SELECT COUNT(*) FROM job_tries");
    my ($narts)  = $dbh->selectrow_array("SELECT COUNT(*) FROM artifacts");
    is($njobs,  1, "job synced to duckdb dest");
    is($ntries, 1, "job_try synced to duckdb dest");
    ok($narts >= 1, "artifact synced to duckdb dest");
    $dbh->disconnect;
};

done_testing;

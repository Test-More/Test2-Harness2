use Test2::V0;

# Schema round-trip for the DB-layer rewrite, driven over the FULL flavor x
# version matrix (#63, step DB-3). For each engine: load the hand-written
# share/schema/<Flavor>.sql, attach the App::Yath2::Schema ORM (DBIx::QuickORM
# autofill / reflect-from-DB), and exercise an insert+read on the core tables --
# the per-engine UUID PK storage, the lowercase *_uuid_string mirror (where the
# engine lacks a native uuid type), the JSON columns, the verdict columns, and the
# collectors hub.
#
#   * SQLite  -- always run (a temp file, no server). The #47 baseline.
#   * PostgreSQL / MySQL / MariaDB / Percona -- EVERY version installed under
#               ~/dbs (plus a system install when ~/dbs lacks the flavor), spun up
#               ephemerally via DBIx::QuickDB. Gated on AUTHOR_TESTING; a single
#               (flavor, version) cell is skipped (never the whole flavor) when it
#               cannot be provisioned. The per-version run is what catches the
#               SQL/typing drift a single-engine run hides.
#
# Per-engine UUID storage (spec §3): native `uuid` on PostgreSQL + MariaDB (no
# string mirror); BINARY(16) + VARCHAR(36) lowercase mirror on MySQL/Percona;
# BLOB(16) + TEXT lowercase mirror on SQLite -- mirror on the `runs` + `jobs`
# tables only (spec §3b). The (flavor, version) discovery + spin-up lives in the
# shared App::Yath2::Test::DBMatrix helper.

use File::Basename qw/dirname/;
use lib dirname(__FILE__) . '/../lib';

use App::Yath2::DB::Flavor;
use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;
use App::Yath2::Test::DBMatrix qw/for_each_db_set/;

use Cpanel::JSON::XS qw/encode_json decode_json/;

# ---------------------------------------------------------------------------
# round_trip($prov) -- the engine-agnostic insert+read assertions run against a
# live connection whose schema came from $prov->{flavor}'s DDL. Reads the engine
# shape (has_string_mirror, json_autotype) from the provision.
#   has_string_mirror   the engine carries the *_uuid_string mirror columns
#                       (BINARY(16)/BLOB(16) engines: mysql/percona/sqlite)
#   json_autotype       QuickORM's JSON autotype inflates/deflates on this engine;
#                       when false the test pre-encodes on write + decodes on read.
# ---------------------------------------------------------------------------
sub round_trip {
    my ($prov) = @_;
    my $flavor            = $prov->{flavor};
    my $con               = $prov->{con};
    my $name              = $flavor->name;
    my $has_string_mirror = $prov->{has_string_mirror};
    my $json_autotype     = $prov->{json_autotype} // 1;

    # JSON marshalling helpers: with autotype, pass/read native refs; without,
    # pre-encode on write and decode on read (the engine stores a JSON string).
    my $json_in  = $json_autotype ? sub { $_[0] } : sub { encode_json($_[0]) };
    my $json_out = $json_autotype ? sub { $_[0] } : sub { defined $_[0] ? decode_json($_[0]) : undef };

    # schema_meta version stamp seeded by the DDL.
    my $meta = $con->handle('schema_meta')->first;
    ok($meta, "[$name] schema_meta row present (version stamp)");
    is($meta->field('yath_version'), '2.000000', "[$name] schema_meta yath_version stamped");

    # natural-key prerequisites (host-local integer identity PKs).
    my $host  = $con->handle('hosts')->insert({hostname => "host.$name"});
    my $proj  = $con->handle('projects')->insert({name => "proj-$name"});
    my $muser = $con->handle('machine_users')->insert({
        host_id  => $host->field('host_id'),
        username => 'osuser',
    });
    my $file = $con->handle('test_files')->insert({
        project_id => $proj->field('project_id'),    # test_files is project-scoped now
        filename   => 't/foo.t',
    });

    ok($host->field('host_id'),          "[$name] host insert returns identity id");
    ok($proj->field('project_id'),       "[$name] project insert returns identity id");
    ok($muser->field('machine_user_id'), "[$name] machine_user insert returns identity id");

    # ---- run (uuid PK + JSON + tri-state booleans) ----
    my $run_uuid = gen_uuid();
    like($run_uuid, qr/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
        "[$name] gen_uuid() is lowercase canonical v7");

    my $run = $con->handle('runs')->insert({
        run_uuid      => $run_uuid,
        project_id    => $proj->field('project_id'),
        host_id       => $host->field('host_id'),
        ran_by        => $muser->field('machine_user_id'),
        passed        => 1,
        failed        => 0,
        to_retry      => 0,
        retried       => 0,
        concurrency_j => 4,
        concurrency_x => 2,
        status        => 'complete',
        canon         => 1,
        duration      => '1.2500',
        version       => '2.000000',
        parameters    => $json_in->({retry_limit => 2, env => 'ci'}),
        fields        => $json_in->([{name => 'git_sha', data => 'abc123'}]),
    });
    ok($run, "[$name] run inserted");

    my $got_run = $con->handle('runs', where => {run_uuid => $run_uuid})->first;
    ok($got_run, "[$name] run fetched by uuid PK");
    is(lc($got_run->field('run_uuid')), $run_uuid, "[$name] run_uuid round-trips as canonical string");
    is($got_run->field('status'), 'complete', "[$name] run status round-trips");
    is($got_run->field('passed'), 1, "[$name] run passed counter round-trips");
    is($got_run->field('canon'),  T(), "[$name] run canon boolean is true");

    # the lowercase *_uuid_string mirror (engines without a native uuid type).
    if ($has_string_mirror) {
        is($got_run->field('run_uuid_string'), $run_uuid,
            "[$name] run_uuid_string mirror is the lowercase canonical form");
    }

    my $params = $json_out->($got_run->field('parameters'));
    is(ref($params), 'HASH', "[$name] parameters JSON is a hashref");
    is($params->{retry_limit}, 2, "[$name] parameters JSON round-trips (retry_limit in params, not a column)");

    my $fields = $json_out->($got_run->field('fields'));
    is(ref($fields), 'ARRAY', "[$name] fields JSON is an arrayref (folded run_fields)");
    is($fields->[0]{name}, 'git_sha', "[$name] fields JSON content round-trips");

    isa_ok($got_run->field('added'), ['DateTime'], "[$name] added timestamp inflated to DateTime");

    # ---- job (uuid PK + folded verdict booleans + the second string mirror) ----
    my $job_uuid = gen_uuid();
    my $job = $con->handle('jobs')->insert({
        job_uuid     => $job_uuid,
        run_uuid     => $run_uuid,
        test_file_id => $file->field('test_file_id'),
        passed       => 1,
        failed       => 0,
    });
    ok($job, "[$name] job inserted");

    my $got_job = $con->handle('jobs', where => {job_uuid => $job_uuid})->first;
    is(lc($got_job->field('job_uuid')), $job_uuid, "[$name] job_uuid round-trips as canonical string");
    if ($has_string_mirror) {
        is($got_job->field('job_uuid_string'), $job_uuid,
            "[$name] job_uuid_string mirror is the lowercase canonical form");
    }

    # ---- job_try (DERIVED single uuid PK + the verdict columns) ----
    my $try_ord      = 1;    # 1-based at the source (R10)
    my $job_try_uuid = derive_uuid($job_uuid, $try_ord);
    isnt($job_try_uuid, $job_uuid, "[$name] derived job_try_uuid (offset>=1) differs from job_uuid");

    my $try = $con->handle('job_tries')->insert({
        job_try_uuid    => $job_try_uuid,
        job_uuid        => $job_uuid,
        try_ord         => $try_ord,
        result          => 1,    # tri-state verdict: pass
        assertion_count => 10,
        pass_count      => 9,
        fail_count      => 1,
        subtests        => 3,
        subtests_passed => 2,
        subtests_failed => 1,
        exit_code       => 0,
        status          => 'complete',
        duration        => '0.5000',
        parameters      => $json_in->({slow => 0}),
        fields          => $json_in->({todo => 'none'}),
    });
    ok($try, "[$name] job_try inserted with verdict columns");

    my $got_try = $con->handle('job_tries', where => {job_try_uuid => $job_try_uuid})->first;
    ok($got_try, "[$name] job_try fetched by derived uuid PK");
    is(lc($got_try->field('job_try_uuid')), $job_try_uuid, "[$name] job_try_uuid round-trips (canonical string)");
    is($got_try->field('try_ord'),         1,    "[$name] try_ord is 1-based");
    is($got_try->field('result'),          T(),  "[$name] result tri-state verdict (true = pass) round-trips");
    is($got_try->field('assertion_count'), 10,   "[$name] assertion_count round-trips");
    is($got_try->field('pass_count'),      9,    "[$name] pass_count round-trips (assertion count, not verdict)");
    is($got_try->field('fail_count'),      1,    "[$name] fail_count round-trips");
    is($got_try->field('subtests'),        3,    "[$name] subtests round-trips");
    is($got_try->field('subtests_passed'), 2,    "[$name] subtests_passed round-trips");
    is($got_try->field('subtests_failed'), 1,    "[$name] subtests_failed round-trips");
    is($got_try->field('exit_code'),       0,    "[$name] exit_code round-trips");

    # in-flight try: result NULL = undecided (tri-state).
    my $job_try_uuid2 = derive_uuid($job_uuid, 2);
    $con->handle('job_tries')->insert({
        job_try_uuid => $job_try_uuid2,
        job_uuid     => $job_uuid,
        try_ord      => 2,
        status       => 'running',
        # result omitted => NULL => in-flight
    });
    my $got_try2 = $con->handle('job_tries', where => {job_try_uuid => $job_try_uuid2})->first;
    is($got_try2->field('result'), undef, "[$name] result NULL = in-flight (tri-state, second try)");

    # ---- collectors (the events producers; test vs service) ----
    # A test collector: carries its job_try, display_name NULL (resolve via the
    # test_file). artifact_uuid == collector_uuid for the events blob (offset 0).
    my $collector_uuid = gen_uuid();
    $con->handle('collectors')->insert({
        collector_uuid => $collector_uuid,
        run_uuid       => $run_uuid,
        job_try_uuid   => $job_try_uuid,
    });
    my $got_col = $con->handle('collectors', where => {collector_uuid => $collector_uuid})->first;
    ok($got_col, "[$name] test collector fetched by uuid PK");
    is($got_col->field('display_name'), undef, "[$name] test collector has NULL display_name (resolve via test_file)");

    # A service collector: NULL job_try + a display_name (the CHECK requires the
    # name when there is no try).
    my $svc_uuid = gen_uuid();
    $con->handle('collectors')->insert({
        collector_uuid => $svc_uuid,
        run_uuid       => $run_uuid,
        display_name   => 'harness',
    });
    my $got_svc = $con->handle('collectors', where => {collector_uuid => $svc_uuid})->first;
    is($got_svc->field('display_name'), 'harness', "[$name] service collector stores display_name");
    is($got_svc->field('job_try_uuid'), undef,     "[$name] service collector has NULL job_try_uuid");

    # A SECOND service collector with NULL job_try -- proves UNIQUE(job_try_uuid)
    # allows multiple NULLs (many service collectors per run) on every engine.
    my $svc_uuid2 = gen_uuid();
    $con->handle('collectors')->insert({
        collector_uuid => $svc_uuid2,
        run_uuid       => $run_uuid,
        display_name   => 'system-load',
    });
    my $got_svc2 = $con->handle('collectors', where => {collector_uuid => $svc_uuid2})->first;
    ok($got_svc2, "[$name] a second NULL-try service collector is allowed (UNIQUE(job_try_uuid) permits multiple NULLs)");

    # ---- artifact (uuid PK, run_uuid NOT NULL, collector_uuid FK, blob data) ----
    my $artifact_uuid = gen_uuid();    # (the real logger derives this; any uuid is fine for the round-trip)
    $con->handle('artifacts')->insert({
        artifact_uuid  => $artifact_uuid,
        run_uuid       => $run_uuid,
        collector_uuid => $collector_uuid,
        filename       => 'events.jsonl.zst',
        local_path     => '/tmp/workdir/events.jsonl.zst',
        data           => "\x00\x01\x02binary",
    });
    my $got_art = $con->handle('artifacts', where => {artifact_uuid => $artifact_uuid})->first;
    ok($got_art, "[$name] artifact fetched by uuid PK");
    is($got_art->field('filename'), 'events.jsonl.zst', "[$name] artifact filename carries the kind");
    is($got_art->field('data'),     "\x00\x01\x02binary", "[$name] artifact blob data round-trips");
}

# ---------------------------------------------------------------------------
# basic flavor-registry sanity (cheap, always runs).
# ---------------------------------------------------------------------------
for my $name (qw/sqlite duckdb postgresql mysql mariadb percona/) {
    my $f = App::Yath2::DB::Flavor->by_name($name);
    ok(-f $f->ddl_path, "$name: share/schema/" . $f->ddl_file . " exists on disk");
}

# ===========================================================================
# Drive the round-trip over the full (flavor, version) matrix.
# ===========================================================================
for_each_db_set(sub {
    my ($set, $prov) = @_;
    ok($prov->{con}, "connected to $set->{name} via QuickORM autofill");
    round_trip($prov);
});

done_testing;

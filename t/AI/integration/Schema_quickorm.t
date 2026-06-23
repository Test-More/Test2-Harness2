use Test2::V0;

# #46 round-trip: spin an ephemeral PostgreSQL via DBIx::QuickDB, load the
# hand-written share/schema/PostgreSQL.sql, attach the App::Yath2::Schema ORM
# (DBIx::QuickORM autofill / reflect-from-DB), and do a basic insert+read on
# `runs` + `job_tries` (incl. a uuid PK and the verdict columns). PostgreSQL is
# the #46 deliverable; this is an integration test because it requires a real
# PostgreSQL server (provisioned ephemerally, torn down at exit).

BEGIN {
    eval { require DBIx::QuickDB; 1 } or skip_all "DBIx::QuickDB not available";
    eval { require DBD::Pg;       1 } or skip_all "DBD::Pg not available";
    require DBIx::QuickDB::Driver::PostgreSQL;
    my ($ok, $why) = DBIx::QuickDB::Driver::PostgreSQL->viable({bootstrap => 1, autostart => 1});
    skip_all "PostgreSQL not provisionable: " . ($why // 'unknown') unless $ok;
}

use App::Yath2::DB::Flavor;
use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;

# QuickORM DSL helpers. 'connect' is renamed so it does not collide.
use DBIx::QuickORM
    rename => {connect => 'qorm_connect'},
    only   => [qw/db dialect connect db_name/];

use App::Yath2::Schema;    # installs qorm() into this package

my $flavor = App::Yath2::DB::Flavor->by_name('postgresql');
is($flavor->dialect, 'PostgreSQL', 'flavor dialect is PostgreSQL');
like($flavor->ddl_path, qr{share/schema/PostgreSQL\.sql$}, 'ddl_path points at PostgreSQL.sql');
ok(-f $flavor->ddl_path, 'PostgreSQL.sql exists on disk (non-empty share/)');

# ---- spin ephemeral PostgreSQL + load the DDL ----
my $qdb = DBIx::QuickDB->build_db(yath_schema_test => {driver => 'PostgreSQL'});

my $bootstrap = $qdb->connect('quickdb', AutoCommit => 1, RaiseError => 1, PrintError => 0);

my $ddl = do {
    open my $fh, '<', $flavor->ddl_path or die "open DDL: $!";
    local $/;
    <$fh>;
};

# Apply statement-by-statement (the DDL is plain top-level statements).
# PostgreSQL emits benign empty NOTICEs that DBD::Pg surfaces as warnings on the
# comment-led statements; silence them so the test output is clean.
for my $stmt (grep { /\S/ } split /;\s*\n/, $ddl) {
    local $SIG{__WARN__} = sub { };
    $bootstrap->do($stmt);
}
$bootstrap->disconnect;

# ---- attach the ORM with autofill (reflect-from-DB) ----
my $orm = qorm(orm => 'yath');

my $cb = sub {
    my $dbh = $qdb->connect('quickdb', AutoCommit => 1, RaiseError => 1, PrintError => 0);
    $flavor->post_connect($dbh);
    return $dbh;
};

$orm->db(db(sub {
    db_name 'quickdb';
    dialect $flavor->dialect;
    qorm_connect($cb);
}));

my $con = $orm->connection;    # autofill introspects the live DB here
ok($con, 'connected to ephemeral PostgreSQL via QuickORM autofill');

# ---- schema_meta version stamp seeded by the DDL ----
my $meta = $con->handle('schema_meta')->first;
ok($meta, 'schema_meta row present (version stamp)');
is($meta->field('yath_version'), '2.000000', 'schema_meta yath_version stamped');

# ---- create the natural-key prerequisites for a run ----
my $host  = $con->handle('hosts')->insert({hostname => 'host.example'});
my $proj  = $con->handle('projects')->insert({name => 'proj-pg'});
my $muser = $con->handle('machine_users')->insert({
    host_id  => $host->field('host_id'),
    username => 'osuser',
});
my $file = $con->handle('test_files')->insert({filename => 't/foo.t'});

ok($host->field('host_id'),           'host insert returns identity id');
ok($proj->field('project_id'),        'project insert returns identity id');
ok($muser->field('machine_user_id'),  'machine_user insert returns identity id');

# ---- insert a run (uuid PK) ----
my $run_uuid = gen_uuid();
like($run_uuid, qr/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    'gen_uuid() is lowercase canonical v7');

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
    parameters    => {retry_limit => 2, env => 'ci'},
    fields        => [{name => 'git_sha', data => 'abc123'}],
});
ok($run, 'run inserted');

# ---- read the run back (fresh row) + verify uuid PK + JSON + tri-state ----
my $got_run = $con->handle('runs', where => {run_uuid => $run_uuid})->first;
ok($got_run, 'run fetched by uuid PK');
is(lc($got_run->field('run_uuid')), $run_uuid, 'run_uuid round-trips as canonical string');
is($got_run->field('status'),       'complete', 'run status round-trips');
is($got_run->field('passed'),       1,          'run passed counter round-trips');
is($got_run->field('canon'),        T(),        'run canon boolean is true');

my $params = $got_run->field('parameters');
is(ref($params), 'HASH', 'parameters JSON inflated to a hashref');
is($params->{retry_limit}, 2, 'parameters JSON content round-trips (retry_limit in params, not a column)');

my $fields = $got_run->field('fields');
is(ref($fields), 'ARRAY', 'fields JSON inflated to an arrayref (folded run_fields)');
is($fields->[0]{name}, 'git_sha', 'fields JSON content round-trips');

isa_ok($got_run->field('added'), ['DateTime'], 'added timestamptz inflated to DateTime');

# ---- insert a job + a job_try with the verdict columns ----
my $job_uuid = gen_uuid();
my $job = $con->handle('jobs')->insert({
    job_uuid       => $job_uuid,
    run_uuid       => $run_uuid,
    test_file_id   => $file->field('test_file_id'),
    is_harness_out => 0,
    passed         => 1,            # folded "any try passed"
    failed         => 0,           # resolved && !passed
});
ok($job, 'job inserted');

# job_try_uuid is the DERIVED single uuid (spec §3.1): derive(job_uuid, try_ord).
my $try_ord      = 1;             # 1-based at the source (R10)
my $job_try_uuid = derive_uuid($job_uuid, $try_ord);
isnt($job_try_uuid, $job_uuid, 'derived job_try_uuid (offset>=1) differs from job_uuid');

my $try = $con->handle('job_tries')->insert({
    job_try_uuid    => $job_try_uuid,
    job_uuid        => $job_uuid,
    try_ord         => $try_ord,
    result          => 1,                 # tri-state verdict: pass
    assertion_count => 10,
    pass_count      => 9,
    fail_count      => 1,
    subtests        => 3,
    subtests_passed => 2,
    subtests_failed => 1,
    exit_code       => 0,
    status          => 'complete',
    duration        => '0.5000',
    parameters      => {slow => 0},
    fields          => {todo => 'none'},
});
ok($try, 'job_try inserted with verdict columns');

# ---- read the job_try back + verify all verdict columns + uuid PK ----
my $got_try = $con->handle('job_tries', where => {job_try_uuid => $job_try_uuid})->first;
ok($got_try, 'job_try fetched by derived uuid PK');
is(lc($got_try->field('job_try_uuid')), $job_try_uuid, 'job_try_uuid round-trips (canonical string)');
is($got_try->field('try_ord'),         1,    'try_ord is 1-based');
is($got_try->field('result'),          T(),  'result tri-state verdict (true = pass) round-trips');
is($got_try->field('assertion_count'), 10,   'assertion_count round-trips');
is($got_try->field('pass_count'),      9,    'pass_count round-trips (assertion count, not verdict)');
is($got_try->field('fail_count'),      1,    'fail_count round-trips');
is($got_try->field('subtests'),        3,    'subtests round-trips');
is($got_try->field('subtests_passed'), 2,    'subtests_passed round-trips');
is($got_try->field('subtests_failed'), 1,    'subtests_failed round-trips');
is($got_try->field('exit_code'),       0,    'exit_code round-trips');

# verdict columns are distinct from result: result is a verdict, the counts are not.
ref_is_not(\$got_try->field('result'), \$got_try->field('pass_count'),
    'result (verdict) and pass_count (count) are separate columns');

# in-flight try: result NULL = undecided (tri-state).
my $job_try_uuid2 = derive_uuid($job_uuid, 2);
my $try2 = $con->handle('job_tries')->insert({
    job_try_uuid => $job_try_uuid2,
    job_uuid     => $job_uuid,
    try_ord      => 2,
    status       => 'running',
    # result omitted => NULL => in-flight
});
my $got_try2 = $con->handle('job_tries', where => {job_try_uuid => $job_try_uuid2})->first;
is($got_try2->field('result'), undef, 'result NULL = in-flight (tri-state, second try)');

# ---- artifact round-trip (uuid PK, run_uuid NOT NULL, job_try_uuid FK, bytea) ----
my $artifact_uuid = gen_uuid();    # (real logger derives this; any uuid is fine for the round-trip)
my $art = $con->handle('artifacts')->insert({
    artifact_uuid => $artifact_uuid,
    run_uuid      => $run_uuid,
    job_try_uuid  => $job_try_uuid,
    filename      => 'events.jsonl.zst',
    local_path    => '/tmp/workdir/events.jsonl.zst',
    data          => "\x00\x01\x02binary",
});
my $got_art = $con->handle('artifacts', where => {artifact_uuid => $artifact_uuid})->first;
ok($got_art, 'artifact fetched by uuid PK');
is($got_art->field('filename'), 'events.jsonl.zst', 'artifact filename carries the kind');
is($got_art->field('data'),     "\x00\x01\x02binary", 'artifact bytea data round-trips');

done_testing;

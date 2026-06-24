use Test2::V0;

# Schema round-trip for the DB-layer rewrite (#46 PostgreSQL / #47 SQLite +
# MySQL/MariaDB/Percona). For each engine: load the hand-written
# share/schema/<Flavor>.sql, attach the App::Yath2::Schema ORM (DBIx::QuickORM
# autofill / reflect-from-DB), and exercise an insert+read on the core tables --
# the per-engine UUID PK storage, the lowercase *_uuid_string mirror (where the
# engine lacks a native uuid type), the JSON columns, and the verdict columns.
#
#   * SQLite  -- always run (DBD::SQLite + QuickORM are the only hard needs; a
#               temp file, no QuickDB server). This is the #47 baseline.
#   * PostgreSQL / MySQL / MariaDB / Percona -- attempt an ephemeral QuickDB
#               round-trip; skip cleanly if the driver/server can't spin up here.
#
# Per-engine UUID storage (spec §3): native `uuid` on PostgreSQL + MariaDB (no
# string mirror); BINARY(16) + VARCHAR(36) lowercase mirror on MySQL/Percona;
# BLOB(16) + TEXT lowercase mirror (lower(hex(...))) on SQLite -- mirror on the
# `runs` + `jobs` tables only (spec §3b).

use App::Yath2::DB::Flavor;
use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;

# QuickORM DSL helpers. 'connect' is renamed so it does not collide. We need the
# ORM-builder DSL (orm/autofill/autotype/autorow) so each engine gets its OWN
# fresh ORM instance: a DBIx::QuickORM::ORM's `db` is settable only once, so the
# shared App::Yath2::Schema `yath` singleton cannot be re-attached to a second
# engine in the same process. Each subtest therefore builds an ORM with the SAME
# autofill block App::Yath2::Schema uses (kept in sync via _attach_yath_autofill).
use DBIx::QuickORM
    rename => {connect => 'qorm_connect'},
    only   => [qw/orm autofill autotype autorow db dialect connect db_name/];

use App::Yath2::Schema;    # also installs qorm() (used for the SQLite baseline)

# ---------------------------------------------------------------------------
# load_ddl($dbh, $flavor) -- apply the flavor's DDL statement-by-statement.
# The DDL files are plain top-level statements separated by ";\n". PostgreSQL
# emits benign empty NOTICEs on the comment-led statements; silence warnings so
# the test output is clean across engines.
# ---------------------------------------------------------------------------
sub load_ddl {
    my ($dbh, $flavor) = @_;
    my $ddl = do {
        open my $fh, '<', $flavor->ddl_path or die "open DDL: $!";
        local $/;
        <$fh>;
    };
    my @stmts = grep { /\S/ } split /;\s*\n/, $ddl;
    for my $stmt (@stmts) {
        local $SIG{__WARN__} = sub { };
        $dbh->do($stmt);
    }
    return scalar @stmts;
}

my $ORM_SEQ = 0;

# ---------------------------------------------------------------------------
# attach_orm($flavor, $db_name, $connect_cb) -- build a FRESH ORM for this engine
# (a DBIx::QuickORM::ORM's `db` is write-once, so each engine needs its own) via
# the exported orm() DSL with the SAME autofill block App::Yath2::Schema
# declares, attach the db, and return the live connection (autofill introspects
# the live DB here).
# ---------------------------------------------------------------------------
sub attach_orm {
    my ($flavor, $db_name, $connect_cb) = @_;

    my $name = 'yath_test_' . $flavor->name . '_' . ++$ORM_SEQ;

    # Mirror of App::Yath2::Schema's autofill block (JSON/UUID/DateTime autotypes
    # + the dumb autorow under App::Yath2::Schema::Row::).
    my $orm = orm($name => sub {
        autofill(sub {
            autotype 'JSON';
            autotype 'UUID';
            autotype 'DateTime';
            autorow 'App::Yath2::Schema::Row';
        });
    });

    $orm->db(db(sub {
        db_name $db_name;
        dialect $flavor->dialect;
        qorm_connect($connect_cb);
    }));
    return $orm->connection;
}

use Cpanel::JSON::XS qw/encode_json decode_json/;

# ---------------------------------------------------------------------------
# round_trip($flavor, $con, %opts) -- the engine-agnostic insert+read assertions
# run against a live connection whose schema came from $flavor's DDL.
#   has_string_mirror => 1   the engine carries the *_uuid_string mirror columns
#                            (BINARY(16)/BLOB(16) engines: mysql/percona/sqlite)
#   json_autotype => 0       QuickORM's JSON autotype does NOT inflate/deflate on
#                            this engine, so the test pre-encodes JSON columns and
#                            decodes them on read. This is true for the MySQL
#                            family: DBD::MariaDB's column_info reflects a `JSON`
#                            column as `LONGTEXT` (MariaDB makes JSON a LONGTEXT
#                            alias; MySQL 8's json also surfaces as LONGTEXT
#                            through this DBD), and the column name isn't "*json*",
#                            so autofill can't claim it. The DDL `JSON` type is
#                            still correct (its json_valid CHECK passes on the
#                            encoded string); wiring an explicit JSON autotype for
#                            the mysql family is the logger's job (#50), not the
#                            #47 DDL port. PostgreSQL (jsonb) + SQLite (preserved
#                            `JSON` type token) autotype fine.
# ---------------------------------------------------------------------------
sub round_trip {
    my ($flavor, $con, %opts) = @_;
    my $name              = $flavor->name;
    my $has_string_mirror = $opts{has_string_mirror};
    my $json_autotype     = $opts{json_autotype} // 1;

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
for my $name (qw/sqlite postgresql mysql mariadb percona/) {
    my $f = App::Yath2::DB::Flavor->by_name($name);
    ok(-f $f->ddl_path, "$name: share/schema/" . $f->ddl_file . " exists on disk");
}

# ===========================================================================
# SQLite -- always-run baseline (#47): temp file, no QuickDB server needed.
# ===========================================================================
subtest sqlite => sub {
    eval { require DBD::SQLite; 1 } or skip_all "DBD::SQLite not available";
    require DBIx::QuickORM;    # the ORM is required for the autofill round-trip

    require File::Temp;
    my $tmp  = File::Temp->newdir(CLEANUP => 1);
    my $path = "$tmp/yath_schema_test.sqlite";

    my $flavor = App::Yath2::DB::Flavor->by_name('sqlite');
    is($flavor->dialect, 'SQLite', 'flavor dialect is SQLite');
    like($flavor->ddl_path, qr{share/schema/SQLite\.sql$}, 'ddl_path points at SQLite.sql');

    my $connect_cb = sub {
        my $dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '',
            {AutoCommit => 1, RaiseError => 1, PrintError => 0});
        $flavor->post_connect($dbh);    # foreign_keys / WAL / busy_timeout PRAGMAs
        return $dbh;
    };

    # load the DDL into the file via a bootstrap handle.
    my $boot  = $connect_cb->();
    my $count = load_ddl($boot, $flavor);
    ok($count > 0, "SQLite.sql loaded ($count statements)");
    $boot->disconnect;

    my $con = attach_orm($flavor, $path, $connect_cb);
    ok($con, 'connected to SQLite via QuickORM autofill');

    # SQLite preserves the declared `JSON` type token, so QuickORM's JSON
    # autotype inflates/deflates the parameters/fields columns natively.
    round_trip($flavor, $con, has_string_mirror => 1, json_autotype => 1);
};

# ===========================================================================
# PostgreSQL / MySQL / MariaDB / Percona -- ephemeral QuickDB if provisionable.
# ===========================================================================
# json_autotype: PostgreSQL (jsonb) reflects + autotypes natively; the MySQL
# family reflects `JSON` as `LONGTEXT` through DBD::MariaDB so the autotype can't
# claim it -- the test pre-encodes/decodes there (see round_trip's json_autotype
# note; wiring an explicit mysql-family JSON autotype is the logger's job, #50).
my %ENGINES = (
    postgresql => {dbd => 'DBD::Pg',    driver => 'PostgreSQL', has_string_mirror => 0, json_autotype => 1},
    mysql      => {dbd => 'DBD::mysql', driver => 'MySQL',      has_string_mirror => 1, json_autotype => 0},
    mariadb    => {dbd => 'DBD::mysql', driver => 'MariaDB',    has_string_mirror => 0, json_autotype => 0},
    percona    => {dbd => 'DBD::mysql', driver => 'Percona',    has_string_mirror => 1, json_autotype => 0},
);

for my $name (qw/postgresql mysql mariadb percona/) {
    my $spec = $ENGINES{$name};
    subtest $name => sub {
        eval { require DBIx::QuickDB; 1 }   or skip_all "DBIx::QuickDB not available";
        eval { require $spec->{dbd}; 1 }
            or do { (my $m = $spec->{dbd}) =~ s{::}{/}g; eval { require "$m.pm"; 1 } }
            or skip_all "$spec->{dbd} not available";

        my $drv = "DBIx::QuickDB::Driver::$spec->{driver}";
        (my $drv_file = "$drv.pm") =~ s{::}{/}g;
        eval { require $drv_file; 1 } or skip_all "$drv not available";
        my ($ok, $why) = $drv->viable({bootstrap => 1, autostart => 1});
        skip_all "$name not provisionable: " . ($why // 'unknown') unless $ok;

        my $flavor = App::Yath2::DB::Flavor->by_name($name);

        my $qdb = DBIx::QuickDB->build_db("yath_schema_$name" => {driver => $spec->{driver}});

        my $connect_cb = sub {
            my $dbh = $qdb->connect('quickdb', AutoCommit => 1, RaiseError => 1, PrintError => 0);
            $flavor->post_connect($dbh);
            return $dbh;
        };

        my $boot  = $connect_cb->();
        my $count = load_ddl($boot, $flavor);
        ok($count > 0, "$flavor->{name} DDL loaded ($count statements)");
        $boot->disconnect;

        my $con = attach_orm($flavor, 'quickdb', $connect_cb);
        ok($con, "connected to ephemeral $name via QuickORM autofill");

        round_trip(
            $flavor, $con,
            has_string_mirror => $spec->{has_string_mirror},
            json_autotype     => $spec->{json_autotype},
        );
    };
}

done_testing;

use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Ticket TODO-45: the old DBIx::Class DB/web layer (App::Yath2::Schema::*) moved to
# reference/old_db and is being rewritten on QuickORM. This BEGIN skip_all runs
# (and exits) before the moved Schema modules are loaded below.
BEGIN { plan skip_all => "App::Yath2::Schema moved to reference/old_db (ticket TODO-45); DB layer is being rewritten" }

#
# Exercise the real logic in the inlined Result-class overlays
# (App::Yath2::Schema::Overlay::*) against an ephemeral SQLite database:
#   - User:   bcrypt password hashing (new/verify/set), gen_api_key
#   - Run:    complete(), sig(), TO_JSON shape, rerun_data
#   - Job:    file/short_file/shortest_file, complete(), glance_data
#   - JobTry: complete(), sig(), glance_data
#   - Event:  TO_JSON, line_data / st_line_data shape
#   - Coverage: human_fields
#   - Project: present (logic exercised via durations needs a real run set)

use strict;
use warnings;

BEGIN {
    # The schema driver must be loaded before anything pulls in the overlays.
    $ENV{YATH_DB_SCHEMA} = 'SQLite';
}

use File::Spec;
use File::Temp qw/tempdir/;

# --- Dependency gate -------------------------------------------------------
BEGIN {
    eval { require DBD::SQLite;                                  1 } or plan skip_all => "DBD::SQLite required: $@";
    eval { require DBIx::Class;                                  1 } or plan skip_all => "DBIx::Class required: $@";
    eval { require DateTime::Format::SQLite;                     1 } or plan skip_all => "DateTime::Format::SQLite required: $@";
    eval { require DBIx::Class::InflateColumn::Serializer::JSON; 1 } or plan skip_all => "InflateColumn::Serializer::JSON required: $@";
    eval { require Crypt::Eksblowfish::Bcrypt;                   1 } or plan skip_all => "Crypt::Eksblowfish::Bcrypt required: $@";
    eval { require Test2::Util::UUID;                            1 } or plan skip_all => "Test2::Util::UUID required: $@";
}

use Test2::Util::UUID qw/gen_uuid/;

# Locate the schema sql relative to this test, so it works from any cwd.
my $here = __FILE__;
my ($vol, $dir) = File::Spec->splitpath($here);
my $root = File::Spec->rel2abs(File::Spec->catdir($dir, File::Spec->updir, File::Spec->updir, File::Spec->updir));
my $sqlfile = File::Spec->catfile($root, qw/share schema SQLite log.sql/);

plan skip_all => "schema sql not found: $sqlfile" unless -f $sqlfile;

# --- Build an ephemeral SQLite DB + deploy the schema ----------------------
my $tmp    = tempdir(CLEANUP => 1);
my $dbpath = File::Spec->catfile($tmp, 'test.db');
my $dsn    = "dbi:SQLite:dbname=$dbpath";

require DBI;
my $now = sub { my @t = localtime; sprintf("%04d-%02d-%02d %02d:%02d:%02d", 1900 + $t[5], 1 + $t[4], @t[3, 2, 1, 0]) };

{
    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, AutoCommit => 1, sqlite_allow_multiple_statements => 1});
    $dbh->sqlite_create_function('now', 0, $now);
    open(my $fh, '<', $sqlfile) or die "Could not open $sqlfile: $!";
    local $/;
    my $sql = <$fh>;
    $dbh->do($sql);
    $dbh->disconnect;
}

require App::Yath2::Schema::SQLite;
require App::Yath2::Schema::Config;

my $config = App::Yath2::Schema::Config->new(dbi_dsn => $dsn, dbi_user => '', dbi_pass => '');
my $schema = $config->schema;
$schema->storage->dbh->sqlite_create_function('now', 0, $now);
$schema->storage->dbh_do(sub { $_[1]->sqlite_create_function('now', 0, $now) });

ok($schema, "connected inlined schema to ephemeral SQLite");

# --------------------------------------------------------------------------
subtest User => sub {
    my $user = $schema->resultset('User')->create({
        username => 'alice',
        role     => 'user',
        password => 'hunter2',
    });

    ok($user->pw_hash, "password hashed into pw_hash on create");
    ok($user->pw_salt, "salt stored in pw_salt on create");
    isnt($user->pw_hash, 'hunter2', "raw password is not stored verbatim");

    ok($user->verify_password('hunter2'),  "verify_password accepts the correct password");
    ok(!$user->verify_password('wrong'),   "verify_password rejects a wrong password");

    # set_password rotates the hash+salt and persists.
    my $old_hash = $user->pw_hash;
    my $old_salt = $user->pw_salt;
    $user->set_password('newpass');
    $user->discard_changes;
    isnt($user->pw_hash, $old_hash, "set_password changed the hash");
    isnt($user->pw_salt, $old_salt, "set_password changed the salt (random)");
    ok($user->verify_password('newpass'),  "verify_password accepts the new password");
    ok(!$user->verify_password('hunter2'), "old password no longer verifies");

    # gen_api_key requires a name and creates an ApiKey row.
    my $key = $user->gen_api_key('ci-token');
    ok($key, "gen_api_key returned a key row");
    is($key->name,   'ci-token', "api key name set");
    is($key->status, 'active',   "api key status defaults to active");
    ok($key->value, "api key has a value (uuid)");

    my $err = dies { $user->gen_api_key() };
    like($err, qr/Must provide a key name/, "gen_api_key dies without a name");
};

# --------------------------------------------------------------------------
# Shared fixture rows for Run/Job/JobTry/Event/Coverage assertions.
my $project = $schema->resultset('Project')->create({name => 'OverlayProj'});
my $owner   = $schema->resultset('User')->create({username => 'bob', role => 'user'});

my $run = $schema->resultset('Run')->create({
    run_uuid      => gen_uuid(),
    user_id       => $owner->user_id,
    project_id    => $project->project_id,
    canon         => 1,
    mode          => 'complete',
    status        => 'pending',
    passed        => 3,
    failed        => 1,
    concurrency_j => 4,
    concurrency_x => 2,
});

my $test_file = $schema->resultset('TestFile')->create({filename => '/abs/path/to/t/foo/bar.t'});

my $job = $schema->resultset('Job')->create({
    job_uuid       => gen_uuid(),
    run_id         => $run->run_id,
    test_file_id   => $test_file->test_file_id,
    is_harness_out => 0,
    failed         => 1,
});

my $try = $schema->resultset('JobTry')->create({
    job_try_uuid => gen_uuid(),
    job_id       => $job->job_id,
    job_try_ord  => 0,
    status       => 'complete',
    fail         => 1,
    pass_count   => 3,
    fail_count   => 1,
    exit_code    => 1,
    duration     => 12.5,
});

# --------------------------------------------------------------------------
subtest Run => sub {
    # complete() maps status -> bool via a fixed set.
    is($run->status, 'pending', "run starts pending");
    ok(!$run->complete, "pending run is not complete");

    $run->update({status => 'complete'});
    $run->discard_changes;
    ok($run->complete, "status=complete -> complete() true");

    $run->update({status => 'broken'});
    ok($run->complete, "status=broken is also 'complete' (terminal)");
    $run->update({status => 'running'});
    ok(!$run->complete, "status=running -> not complete");
    $run->update({status => 'complete'});

    # sig() is a stable string summary; assert it embeds the key fields.
    my $sig = $run->sig;
    ok($sig, "sig() returns a value");
    like($sig, qr/complete/, "sig includes status");
    like($sig, qr/;4;2;/,   "sig includes concurrency_j (4) and concurrency_x (2)");

    # TO_JSON: hashref with derived user/project names + fields list + added.
    my $json = $run->TO_JSON;
    is(ref($json), 'HASH', "TO_JSON returns a hashref");
    is($json->{user},    'bob',         "TO_JSON derives username");
    is($json->{project}, 'OverlayProj', "TO_JSON derives project name");
    is(ref($json->{fields}), 'ARRAY', "TO_JSON includes a fields arrayref");
    like($json->{added}, qr/^\d{4}-\d{2}-\d{2}/, "TO_JSON formats 'added' as a date string");

    # rerun_data: keyed by test file, counting pass/fail across tries.
    my $rerun = $run->rerun_data;
    is(ref($rerun), 'HASH', "rerun_data returns a hashref");
    ok(exists $rerun->{'/abs/path/to/t/foo/bar.t'}, "rerun_data keyed by test file");
    is($rerun->{'/abs/path/to/t/foo/bar.t'}{fail}, 1, "rerun_data counted the failing try");
};

# --------------------------------------------------------------------------
subtest Job => sub {
    is($job->file, '/abs/path/to/t/foo/bar.t', "file() falls back to test_file->filename");
    is($job->shortest_file, 'bar.t', "shortest_file() is the basename");
    is($job->short_file, 't/foo/bar.t', "short_file() trims to the t/ path form");

    # complete(): the single try is complete and not a retry -> job complete.
    ok($job->complete, "job with a single complete try is complete");

    # glance_data: one entry per try, merged job+try fields.
    my @glance = $job->glance_data;
    is(scalar(@glance), 1, "glance_data returns one entry per try");
    is($glance[0]{file}, '/abs/path/to/t/foo/bar.t', "glance entry carries file");
    is($glance[0]{status}, 'complete', "glance entry carries try status");
    is($glance[0]{job_uuid}, $job->job_uuid, "glance entry carries job_uuid");

    # TO_JSON adds short_file / shortest_file.
    my $json = $job->TO_JSON;
    is($json->{short_file},    't/foo/bar.t', "TO_JSON short_file");
    is($json->{shortest_file}, 'bar.t',       "TO_JSON shortest_file (basename)");
};

# --------------------------------------------------------------------------
subtest JobTry => sub {
    ok($try->complete, "status=complete try is complete()");

    my $sig = $try->sig;
    ok($sig, "sig() returns a value");
    # GLANCE_FIELDS order: exit_code fail job_try_ord job_try_id ... status duration
    like($sig, qr/^1:1:0:/, "sig starts exit_code:fail:job_try_ord");
    like($sig, qr/:complete:/, "sig includes status");

    my $glance = $try->glance_data;
    is(ref($glance), 'HASH', "glance_data returns a hashref");
    is($glance->{status},   'complete', "glance status");
    is($glance->{fail},     1,          "glance fail");
    is($glance->{duration}, 12.5,       "glance duration");
    is(ref($glance->{fields}), 'ARRAY', "glance includes fields arrayref");
};

# --------------------------------------------------------------------------
subtest Event => sub {
    my $event = $schema->resultset('Event')->create({
        event_uuid  => gen_uuid(),
        job_try_id  => $try->job_try_id,
        event_idx   => 0,
        event_sdx   => 0,
        nested      => 0,
        is_subtest  => 1,
        is_diag     => 0,
        is_harness  => 0,
        is_time     => 0,
        is_orphan   => 0,
        causes_fail => 1,
        has_facets  => 1,
        has_binary  => 0,
        rendered    => [['info', 'line one'], ['info', 'line two']],
    });

    my $json = $event->TO_JSON;
    is(ref($json), 'HASH', "Event TO_JSON returns a hashref");
    is($json->{event_uuid}, $event->event_uuid, "TO_JSON includes event_uuid");

    my $ld = $event->line_data;
    is(ref($ld), 'HASH', "line_data returns a hashref");
    is($ld->{is_parent}, 1, "is_subtest reflected as is_parent");
    is($ld->{is_fail},   1, "causes_fail reflected as is_fail");
    is($ld->{facets},    1, "has_facets reflected");
    is($ld->{orphan},    0, "not orphan");
    is($ld->{lines}, [['info', 'line one'], ['info', 'line two']], "rendered JSON inflated into lines");
    is($ld->{event_uuid}, $event->event_uuid, "line_data carries event_uuid");

    # st_line_data is line_data + loading_subtest flag.
    my $st = $event->st_line_data;
    is($st->{loading_subtest}, 1, "st_line_data sets loading_subtest");
    is($st->{is_parent}, 1, "st_line_data still carries the base line_data");
};

# --------------------------------------------------------------------------
subtest Coverage => sub {
    my $src_file = $schema->resultset('SourceFile')->create({filename => 'lib/My/Mod.pm'});
    my $src_sub  = $schema->resultset('SourceSub')->create({subname => 'do_thing'});

    my $cover = $schema->resultset('Coverage')->create({
        event_uuid     => gen_uuid(),
        run_id         => $run->run_id,
        test_file_id   => $test_file->test_file_id,
        source_file_id => $src_file->source_file_id,
        source_sub_id  => $src_sub->source_sub_id,
        metadata       => ['*'],
    });
    # Reload so server-side defaults (e.g. coverage_manager_id) are populated
    # before manager_package() walks the relationship.
    $cover->discard_changes;

    my $hf = $cover->human_fields;
    is(ref($hf), 'HASH', "human_fields returns a hashref");
    is($hf->{test_file},   '/abs/path/to/t/foo/bar.t', "human_fields resolves test_file filename");
    is($hf->{source_file}, 'lib/My/Mod.pm', "human_fields resolves source_file filename");
    is($hf->{source_sub},  'do_thing',      "human_fields resolves source_sub name");
    is($hf->{manager},     undef,           "no coverage_manager -> manager undef");
    is($hf->{metadata},    ['*'],           "metadata inflated from JSON");
};

# --------------------------------------------------------------------------
subtest Project => sub {
    # durations(): pulls job_try durations grouped by test file (median).
    # Our fixture has one try (12.5s) for t/foo/bar.t under this project.
    my $data = $project->durations;
    is(ref($data), 'HASH', "durations returns a hashref");
    ok(exists $data->{lookup}, "durations has a lookup map");
    ok(exists $data->{sorted}, "durations has a sorted list");
    is($data->{lookup}{'/abs/path/to/t/foo/bar.t'} + 0, 12.5, "median duration for the single try is 12.5");
    is($data->{sorted}, ['/abs/path/to/t/foo/bar.t'], "sorted lists the test file");

    # last_covered_run: no run has has_coverage=1 yet -> undef.
    is($project->last_covered_run, undef, "last_covered_run undef when no covered run");
};

done_testing;

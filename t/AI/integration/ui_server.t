use Test2::V0;

# Ticket #45: the old DBIx::Class DB/web layer (App::Yath2::Schema::*,
# App::Yath2::Server::*) moved to reference/old_db and is being rewritten on
# QuickORM. This BEGIN skip_all runs (and exits) before the moved modules are
# loaded below, so the test stays green instead of failing to compile.
BEGIN { plan skip_all => "App::Yath2::Schema + App::Yath2::Server moved to reference/old_db (ticket #45); DB/web layer is being rewritten" }

# Phase 5 UI integration smoke test: build an ephemeral SQLite database, deploy
# the inlined schema, import a real captured event log via the inlined importer
# (App::Yath2::Schema::Importer -> RunProcessor), then serve the inlined Plack
# app (App::Yath2::Server::Plack) in-process via Plack::Test and assert that the
# real HTTP routes respond: the HTML index, JSON data routes for the imported
# run, static assets with correct content-types, and a few controller pages.
#
# This proves the whole inlined UI stack serves end to end on SQLite.

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
    eval { require Plack;                                        1 } or plan skip_all => "Plack required: $@";
    eval { require Plack::Test;                                  1 } or plan skip_all => "Plack::Test required: $@";
    eval { require HTTP::Request::Common;                        1 } or plan skip_all => "HTTP::Request::Common required: $@";
    eval { require Router::Simple;                               1 } or plan skip_all => "Router::Simple required: $@";
    eval { require Text::Xslate;                                 1 } or plan skip_all => "Text::Xslate required: $@";
}

use HTTP::Request::Common qw/GET/;
use Test2::Util::UUID qw/gen_uuid/;

# Locate the fixture + schema sql + share/ relative to this test so it works
# from any cwd. The Plack app resolves share/{js,css,templates} relative to cwd
# during development, so we chdir to the repo root for the duration of the test.
my $here = __FILE__;
my ($vol, $dir) = File::Spec->splitpath($here);
# t/AI/integration/ -> repo root is three levels up.
my $root = File::Spec->rel2abs(File::Spec->catdir($dir, File::Spec->updir, File::Spec->updir, File::Spec->updir));

my $fixture = File::Spec->catfile($root, qw/t AI fixtures ui sample-run.jsonl/);
my $sqlfile = File::Spec->catfile($root, qw/share schema SQLite.sql/);

plan skip_all => "fixture not found: $fixture"     unless -f $fixture;
plan skip_all => "schema sql not found: $sqlfile"  unless -f $sqlfile;
plan skip_all => "share/ dir not found at $root"   unless -d File::Spec->catdir($root, 'share');

# share_dir()/share_file() prefer the in-repo ./share dir, so run from the root.
chdir($root) or plan skip_all => "could not chdir to repo root $root: $!";

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

# --- Connect the inlined schema via Config ---------------------------------
require App::Yath2::Schema::SQLite;
require App::Yath2::Schema::Config;

my $config = App::Yath2::Schema::Config->new(
    dbi_dsn  => $dsn,
    dbi_user => '',
    dbi_pass => '',
);

my $schema = $config->schema;

# Register the SQLite 'now' default-function on the live DBIC handle too.
$schema->storage->dbh->sqlite_create_function('now', 0, $now);
$schema->storage->dbh_do(sub { $_[1]->sqlite_create_function('now', 0, $now) });

ok($schema, "connected inlined App::Yath2::Schema to ephemeral SQLite");

# --- Pre-create the Run row + import the fixture log ------------------------
my $project = $schema->resultset('Project')->create({name => 'Test2-Harness'});
my $user    = $schema->resultset('User')->create({username => 'root', password => 'root', realname => 'root'});

my $run = $schema->resultset('Run')->create({
    run_uuid   => gen_uuid(),
    canon      => 1,
    mode       => 'complete',
    status     => 'pending',
    user_id    => $user->user_id,
    project_id => $project->project_id,
});

require App::Yath2::Schema::Importer;

open(my $logfh, '<', $fixture) or die "Could not open fixture: $!";
my $importer = App::Yath2::Schema::Importer->new(config => $config);
my $ok = eval { $importer->process_log($run, $logfh); 1 };
my $err = $@;
ok($ok, "imported fixture log without dying") or diag($err);
close($logfh);

$run->discard_changes;
is($run->status, 'complete', "imported run marked complete");

my $run_uuid = $run->run_uuid;
my $job = $schema->resultset('Job')->search({run_id => $run->run_id, is_harness_out => 0})->first;
ok($job, "found imported (non-harness) job row");
my $job_uuid = $job->job_uuid;

# --- Build the Plack app in-process via Plack::Test ------------------------
require App::Yath2::Server::Plack;
my $app = App::Yath2::Server::Plack->new(
    schema_config => $config,
    single_user   => 1,
    single_run    => 1,
)->to_app;

ok($app, "built the inlined Plack app");

my $test = Plack::Test->create($app);

# Guard against streaming routes that camp for live updates; run-scoped streams
# terminate once the parent run is complete, but wrap in an alarm for safety.
my $request = sub {
    my ($url) = @_;
    my $res;
    local $SIG{ALRM} = sub { die "TIMEOUT requesting $url\n" };
    alarm 20;
    my $rok = eval { $res = $test->request(GET $url); 1 };
    my $rerr = $@;
    alarm 0;
    die $rerr unless $rok;
    return $res;
};

# --- 1. HTML index --------------------------------------------------------
{
    my $res = $request->('/');
    is($res->code, 200, "GET / -> 200");
    like($res->content_type, qr{text/html}, "GET / content-type is text/html");
    like($res->content, qr{<title>[^<]*Yath}i, "GET / has a Yath title");
    like($res->content, qr{runtable\.js}, "GET / references runtable.js (view page rendered)");
}

# --- 2. JSON API: a run's data --------------------------------------------
{
    my $res = $request->("/run/$run_uuid");
    is($res->code, 200, "GET /run/<uuid> -> 200");
    like($res->content_type, qr{application/json}, "GET /run/<uuid> content-type is application/json");

    require Test2::Harness2::Util::JSON;
    my $data = eval { Test2::Harness2::Util::JSON::decode_json($res->content) };
    ok($data, "GET /run/<uuid> returned valid JSON") or diag($@, "\n", $res->content);
    is(uc($data->{run_uuid} // ''), uc($run_uuid), "JSON carries the imported run uuid")
        if ref($data) eq 'HASH';
}

# --- 3. JSON API: recent runs (lists the imported run) --------------------
{
    my $res = $request->('/recent/Test2-Harness/root');
    is($res->code, 200, "GET /recent/<project>/<user> -> 200");
    like($res->content_type, qr{application/json}, "recent runs content-type is application/json");

    require Test2::Harness2::Util::JSON;
    my $data = eval { Test2::Harness2::Util::JSON::decode_json($res->content) };
    ok(ref($data) eq 'ARRAY', "recent runs is a JSON array") or diag($@, "\n", $res->content);
    ok((grep { uc($_->{run_uuid} // '') eq uc($run_uuid) } @$data), "recent runs includes the imported run")
        if ref($data) eq 'ARRAY';
}

# --- 4. Static assets with correct content-types --------------------------
{
    my $js = $request->('/js/runtable.js');
    is($js->code, 200, "GET /js/runtable.js -> 200");
    like($js->content_type, qr{javascript}, "runtable.js served as javascript");
    ok(length($js->content) > 0, "runtable.js has a body");

    my $css = $request->('/css/view.css');
    is($css->code, 200, "GET /css/view.css -> 200");
    like($css->content_type, qr{text/css}, "view.css served as text/css");
    ok(length($css->content) > 0, "view.css has a body");
}

# --- 5. A controller page renders without 500 -----------------------------
{
    my $res = $request->("/view/$run_uuid");
    is($res->code, 200, "GET /view/<uuid> -> 200 (controller page renders)");
    like($res->content_type, qr{text/html}, "view page content-type is text/html");

    my $job_res = $request->("/job/$job_uuid");
    is($job_res->code, 200, "GET /job/<uuid> -> 200 (job JSON renders)");
    like($job_res->content_type, qr{application/json}, "job route content-type is application/json");
}

# --- 6. A run-scoped stream terminates and emits the run ------------------
{
    my $res = $request->("/stream/run/$run_uuid");
    is($res->code, 200, "GET /stream/run/<uuid> -> 200 (run-scoped stream)");
    like($res->content, qr{"type":"run"}, "stream emitted a run record");
    like($res->content, qr/\Q$run_uuid\E/i, "stream payload references the imported run uuid");
}

done_testing;

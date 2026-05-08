use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

# Build a minimal synthetic log directory: one global service and one run
# with one job/try. Enough for a complete archive round-trip.
sub build_minimal_log {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
        my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    # spec.jsonl -- required now that jobs.test_file_id is NOT NULL.
    my $w = open_zstd_writer("$src/runs/0/jobs/0/0/spec.jsonl.zst");
    $w->say(encode_json({relative => 't/dummy.t'}));
    $w->close;

    return $src;
}

# Helper: override App::Yath2::Log::build_archive_meta to inject a
# specific project name, then restore it. This avoids SUPER:: complexity
# by building the full replacement inline.
my $real_build_archive_meta = App::Yath2::Log->can('build_archive_meta');
sub with_project {
    my ($project_name, $code) = @_;
    no warnings 'redefine';
    local *App::Yath2::Log::build_archive_meta = sub {
        my ($class, %p) = @_;
        my $meta = $real_build_archive_meta->($class, %p);
        $meta->{project} = $project_name;
        return $meta;
    };
    use warnings 'redefine';
    $code->();
}

for_each_log_db_backend(sub {
    my ($backend) = @_;

    # --- Part 1: ensure_project_row unit-level test ---

    my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $db_path;
    my $db = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
    $db->bootstrap_schema;

    # ensure_project_row is the canonical backend primitive; both
    # backends expose it directly.
    my $sql_helper = $db;

    {
        my $id1 = $sql_helper->ensure_project_row('myproj');
        ok(defined $id1, 'ensure_project_row returns an id for new project');

        my $id2 = $sql_helper->ensure_project_row('myproj');
        is($id2, $id1, 'second call with same name returns same project_id (idempotent)');

        my $id3 = $sql_helper->ensure_project_row('otherproj');
        ok(defined $id3, 'distinct project gets its own id');
        isnt($id3, $id1, 'distinct project id differs from first');

        my $dbh = $db->dbh;
        my ($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM projects');
        is($count, 2, 'projects table has exactly 2 rows');

        my @names = map { $_->[0] }
            @{ $dbh->selectall_arrayref('SELECT name FROM projects ORDER BY name') };
        is(\@names, [qw/myproj otherproj/], 'project names correct');
    }

    # --- Part 2: full insert() integration ---

    (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $db_path;
    $db = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
    $db->bootstrap_schema;

    my $src = build_minimal_log();
    my $dbh = $db->dbh;

    # First insert: project='myproj'
    my $aid1;
    with_project('myproj', sub {
        my $dir_log = App::Yath2::Log->new(dir => $src);
        $aid1 = $db->insert($dir_log);
    });
    ok(defined $aid1, 'first insert() returned an archive_id');

    # One project row.
    my ($proj_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM projects');
    is($proj_count, 1, 'one project row after first insert');

    my ($proj_id) = $dbh->selectrow_array(
        'SELECT project_id FROM projects WHERE name = ?', undef, 'myproj',
    );
    ok(defined $proj_id, 'myproj project row exists');

    # runs.project_id must match.
    my ($run_proj_id) = $dbh->selectrow_array(
        'SELECT project_id FROM runs WHERE archive_id = ?', undef, $aid1,
    );
    is($run_proj_id, $proj_id, 'runs.project_id matches projects.project_id');

    # Second insert with same project name: still only one project row.
    my $aid2;
    with_project('myproj', sub {
        my $dir_log2 = App::Yath2::Log->new(dir => $src);
        $aid2 = $db->insert($dir_log2);
    });
    ok(defined $aid2, 'second insert() succeeded');

    ($proj_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM projects');
    is($proj_count, 1, 'still one project row after re-archiving same project name');

    # Third insert with a different project.
    my $aid3;
    with_project('otherproj', sub {
        my $dir_log3 = App::Yath2::Log->new(dir => $src);
        $aid3 = $db->insert($dir_log3);
    });
    ok(defined $aid3, 'third insert (new project) succeeded');

    ($proj_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM projects');
    is($proj_count, 2, 'two project rows after insert with a different project name');

    my ($run3_proj_id) = $dbh->selectrow_array(
        'SELECT project_id FROM runs WHERE archive_id = ?', undef, $aid3,
    );
    my ($otherproj_id) = $dbh->selectrow_array(
        'SELECT project_id FROM projects WHERE name = ?', undef, 'otherproj',
    );
    is($run3_proj_id, $otherproj_id,
        'third archive runs.project_id points to otherproj');
});

done_testing;

use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::DB::Sqlite;

# Helper: override App::Yath2::Log::build_archive_meta to inject a
# specific project name.
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

# Build a synthetic log directory with one job whose spec.jsonl
# contains a 'relative' key.
sub build_log_with_job {
    my (%opts) = @_;
    my $relative = $opts{relative} // 't/foo.t';
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    # Harness global service events.
    {
        my $w = open_zstd_writer("$src/services/harness/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    # Run events.
    {
        my $w = open_zstd_writer("$src/runs/0/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    # Job try events.
    {
        my $w = open_zstd_writer("$src/runs/0/jobs/0/0/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    # Job try spec.jsonl with relative + absolute paths.
    {
        my $w = open_zstd_writer("$src/runs/0/jobs/0/0/spec.jsonl.zst");
        $w->say(encode_json({
            relative => $relative,
            absolute => "/home/user/$relative",
            category => 'medium',
            started_at => '2026-01-01T00:00:00Z',
        }));
        $w->close;
    }

    return $src;
}

# --- Part 1: _resolve_or_create_test_file unit-level test ---

my $tmp_dir = tempdir(CLEANUP => 1);

{
    my $db_path = "$tmp_dir/unit.yath";
    my $db = App::Yath2::Log::DB::Sqlite->new(dsn => "dbi:SQLite:$db_path");
    $db->bootstrap_schema;

    # Seed a project row for FK.
    my $proj_id = $db->_resolve_or_create_project('myproj');

    my $id1 = $db->_resolve_or_create_test_file($proj_id, 't/foo.t');
    ok(defined $id1, '_resolve_or_create_test_file returns id for new file');

    my $id2 = $db->_resolve_or_create_test_file($proj_id, 't/foo.t');
    is($id2, $id1, 'idempotent: second call returns same test_file_id');

    my $id3 = $db->_resolve_or_create_test_file($proj_id, 't/bar.t');
    ok(defined $id3, 'distinct relative path gets its own id');
    isnt($id3, $id1, 'distinct test_file id differs from first');

    # Second project: same relative path -> different test_file_id.
    my $proj2 = $db->_resolve_or_create_project('otherproj');
    my $id4 = $db->_resolve_or_create_test_file($proj2, 't/foo.t');
    ok(defined $id4, 'same relative path under different project gets its own id');
    isnt($id4, $id1, 'cross-project test_file ids differ');

    my $dbh = $db->dbh;
    my ($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM test_files');
    is($count, 3, 'test_files table has 3 rows');

    # Verify error on missing args.
    like(dies { $db->_resolve_or_create_test_file(undef, 't/foo.t') },
         qr/project_id required/, 'croaks on missing project_id');
    like(dies { $db->_resolve_or_create_test_file($proj_id, '') },
         qr/relative path required/, 'croaks on empty relative');

    $db->dbh->disconnect;
}

# --- Part 2: full insert() integration with test_files ---

my $db_path = "$tmp_dir/integration.yath";
my $db = App::Yath2::Log::DB::Sqlite->new(dsn => "dbi:SQLite:$db_path");
$db->bootstrap_schema;

my $src1 = build_log_with_job(relative => 't/foo.t');
my $src2 = build_log_with_job(relative => 't/bar.t');
my $dbh  = $db->dbh;

# Insert first archive: job runs t/foo.t.
my $aid1;
with_project('myproj', sub {
    $aid1 = $db->insert(App::Yath2::Log->new(dir => $src1));
});
ok(defined $aid1, 'first insert succeeded');

# test_files: one row for t/foo.t.
my ($tf_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM test_files');
is($tf_count, 1, 'one test_files row after first insert');

my $tf_row = $dbh->selectrow_hashref(
    q{SELECT tf.*, p.name AS proj_name
        FROM test_files tf
        JOIN projects p ON tf.project_id = p.project_id
       WHERE tf.relative = ?},
    undef, 't/foo.t',
);
ok(defined $tf_row, 'test_files row for t/foo.t exists');
is($tf_row->{proj_name}, 'myproj', 'test_files.project_id points to myproj');

# jobs.test_file_id must point to the test_files row.
my $job_row = $dbh->selectrow_hashref(
    q{SELECT j.* FROM jobs j
        JOIN runs r ON j.run_id = r.run_id
       WHERE r.archive_id = ?},
    undef, $aid1,
);
ok(defined $job_row, 'jobs row exists');
is($job_row->{test_file_id}, $tf_row->{test_file_id},
    'jobs.test_file_id FK matches test_files row');

# Insert second archive: job runs t/bar.t (same project).
my $aid2;
with_project('myproj', sub {
    $aid2 = $db->insert(App::Yath2::Log->new(dir => $src2));
});
ok(defined $aid2, 'second insert (different test file) succeeded');

($tf_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM test_files');
is($tf_count, 2, 'two test_files rows after second insert (different files)');

# Re-insert the first archive: same test file -> no duplicate test_files row.
my $aid3;
with_project('myproj', sub {
    $aid3 = $db->insert(App::Yath2::Log->new(dir => $src1));
});
ok(defined $aid3, 'third insert (re-run same file) succeeded');

($tf_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM test_files');
is($tf_count, 2, 'still two test_files rows after re-archiving same test file');

# But jobs has 3 rows (one per archive insert).
my ($job_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM jobs');
is($job_count, 3, '3 jobs rows across 3 inserts');

# All jobs for t/foo.t archives share the same test_file_id.
my @foo_tf_ids = map { $_->[0] } @{
    $dbh->selectall_arrayref(q{
        SELECT DISTINCT j.test_file_id
          FROM jobs j
          JOIN runs r ON j.run_id = r.run_id
         WHERE r.archive_id IN (?, ?)
    }, undef, $aid1, $aid3)
};
is(scalar @foo_tf_ids, 1, 't/foo.t jobs in two archives share one test_file_id');
is($foo_tf_ids[0], $tf_row->{test_file_id}, 'shared test_file_id is the t/foo.t row');

done_testing;

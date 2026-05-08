use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::DB::Sqlite;

# C1: Cross-archive aggregate test.
#
# Build 3 archives in the same DB with the same project name. Each
# archive contains one run with two jobs: t/foo.t and t/bar.t. The
# 'category' field on each spec.jsonl varies per-archive so we can
# assert the aggregate query returns the per-archive history of any
# given test_file under a project_id.

# Helper: override App::Yath2::Log::build_archive_meta to inject a
# specific project name. Same pattern used in the projects.t test.
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

# Build a minimal synthetic log directory containing one run with two
# jobs (t/foo.t at job 0, t/bar.t at job 1). Each job's spec.jsonl
# carries a per-archive category value.
sub build_log {
    my (%opts) = @_;
    my $foo_category = $opts{foo_category} // 'A';
    my $bar_category = $opts{bar_category} // 'X';

    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");
    make_path("$src/runs/0/jobs/1/0");

    # Globals + run + each job-try get a placeholder events stream so
    # the source looks structurally complete.
    for my $base ('services/harness', 'runs/0',
                  'runs/0/jobs/0/0', 'runs/0/jobs/1/0') {
        my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    # Job 0: t/foo.t with $foo_category.
    {
        my $w = open_zstd_writer("$src/runs/0/jobs/0/0/spec.jsonl.zst");
        $w->say(encode_json({
            relative => 't/foo.t',
            absolute => '/home/user/t/foo.t',
            category => $foo_category,
        }));
        $w->close;
    }

    # Job 1: t/bar.t with $bar_category.
    {
        my $w = open_zstd_writer("$src/runs/0/jobs/1/0/spec.jsonl.zst");
        $w->say(encode_json({
            relative => 't/bar.t',
            absolute => '/home/user/t/bar.t',
            category => $bar_category,
        }));
        $w->close;
    }

    return $src;
}

# Fresh DB.
my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $db_path;
my $db  = App::Yath2::Log::DB::Sqlite->new(dsn => "dbi:SQLite:$db_path");
$db->bootstrap_schema;
my $dbh = $db->dbh;

# Three archives, all under project 'shared_project'. Each one
# carries a different category for both t/foo.t and t/bar.t. Each
# insert() generates a fresh archive_uuid via gen_uuid() so the
# B8 duplicate-archive guard does not fire.
my @archives = (
    { foo => 'A', bar => 'X' },
    { foo => 'B', bar => 'Y' },
    { foo => 'C', bar => 'Z' },
);

my @aids;
for my $arc (@archives) {
    my $src = build_log(foo_category => $arc->{foo},
                        bar_category => $arc->{bar});
    my $aid;
    with_project('shared_project', sub {
        $aid = $db->insert(App::Yath2::Log->new(dir => $src));
    });
    ok(defined $aid, "insert for archive ($arc->{foo}/$arc->{bar}) succeeded");
    push @aids, $aid;
}

is(scalar @aids, 3, 'three archives inserted');

# Confirm one project row.
my ($proj_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM projects');
is($proj_count, 1, 'exactly one project row');

my ($proj_id) = $dbh->selectrow_array(
    'SELECT project_id FROM projects WHERE name = ?',
    undef, 'shared_project',
);
ok(defined $proj_id, 'shared_project project_id exists');

# test_files dedup proof: two rows total (t/foo.t + t/bar.t) for
# this project, even though the two relatives appeared in three
# archives each.
my ($tf_count) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM test_files WHERE project_id = ?',
    undef, $proj_id,
);
is($tf_count, 2, 'test_files has exactly 2 rows for the shared project');

my @tf_rels = map { $_->[0] } @{
    $dbh->selectall_arrayref(
        'SELECT relative FROM test_files WHERE project_id = ? ORDER BY relative',
        undef, $proj_id,
    )
};
is(\@tf_rels, ['t/bar.t', 't/foo.t'],
    'test_files rows are t/bar.t and t/foo.t');

# The aggregate query under test: for a given (project_id, relative),
# return the category history across all archives, ordered by
# archive insertion order.
my $sql = q{
    SELECT a.archive_uuid, js.category
      FROM job_specs js
      JOIN test_files tf ON js.test_file_id = tf.test_file_id
      JOIN jobs j        ON js.job_id      = j.job_id
      JOIN runs r        ON j.run_id       = r.run_id
      JOIN archives a    ON r.archive_id   = a.archive_id
     WHERE tf.relative   = ?
       AND tf.project_id = ?
     ORDER BY a.archive_id
};

# t/foo.t -> categories ['A', 'B', 'C'] in archive insertion order.
my $foo_rows = $dbh->selectall_arrayref($sql, undef, 't/foo.t', $proj_id);
is(scalar @$foo_rows, 3, 'aggregate query returns 3 rows for t/foo.t');
my @foo_cats = map { $_->[1] } @$foo_rows;
is(\@foo_cats, ['A', 'B', 'C'],
    't/foo.t category history is A, B, C across archives');

# t/bar.t -> ['X', 'Y', 'Z'].
my $bar_rows = $dbh->selectall_arrayref($sql, undef, 't/bar.t', $proj_id);
is(scalar @$bar_rows, 3, 'aggregate query returns 3 rows for t/bar.t');
my @bar_cats = map { $_->[1] } @$bar_rows;
is(\@bar_cats, ['X', 'Y', 'Z'],
    't/bar.t category history is X, Y, Z across archives');

# Sanity: the archive_uuids returned for foo and bar in the same
# order match the archives we inserted (each row pair shares the
# same archive_uuid because both jobs live in the same run).
my @foo_uuids = map { $_->[0] } @$foo_rows;
my @bar_uuids = map { $_->[0] } @$bar_rows;
is(\@foo_uuids, \@bar_uuids,
    'archive_uuid sequence matches between foo.t and bar.t aggregates');

# Cross-check: each row's archive_id must match the archives we
# inserted, in the same order.
my $sql_with_ids = q{
    SELECT a.archive_id, js.category
      FROM job_specs js
      JOIN test_files tf ON js.test_file_id = tf.test_file_id
      JOIN jobs j        ON js.job_id      = j.job_id
      JOIN runs r        ON j.run_id       = r.run_id
      JOIN archives a    ON r.archive_id   = a.archive_id
     WHERE tf.relative   = ?
       AND tf.project_id = ?
     ORDER BY a.archive_id
};
my $foo_id_rows = $dbh->selectall_arrayref(
    $sql_with_ids, undef, 't/foo.t', $proj_id);
my @aggregate_aids = map { $_->[0] } @$foo_id_rows;
is(\@aggregate_aids, \@aids,
    'aggregate query archive_ids match insertion order');

done_testing;

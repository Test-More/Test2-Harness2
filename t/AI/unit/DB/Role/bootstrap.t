use Test2::V0;
use File::Temp qw/tempdir/;
use DBI;

use App::Yath2::Role::DB::Backend;

# Build a minimal consumer + a fixture share/schema/sqlite.sql.
{
    package Test::Boot::Fake;
    use Role::Tiny::With;
    for my $m (qw{
        archive_rows archive_for_uuid archive_count archive_create mark_sealed
        run_rows service_rows job_rows try_rows
        run_exists job_exists try_exists service_exists
        run_id_for_ord job_id_for_ord try_id_for_ord service_id_for_name
        ensure_project_row ensure_test_file_row ensure_run_row
        ensure_service_row ensure_job_row ensure_job_try_row
        artifact_rows_for_archive artifact_row_for_scope artifact_payload
        artifact_create artifact_update artifact_event_count_for_archive
        job_spec_rows service_lifetime_rows subtest_rows
        job_spec_create service_lifetime_create subtest_create
    }) {
        no strict 'refs';
        *{$m} = sub { die "$m unimplemented" };
    }
    sub new {
        my ($c, %p) = @_;
        bless { %p }, $c;
    }
    sub dbh    { $_[0]->{dbh} }
    sub flavor { 'sqlite' }
    sub schema_file { $_[0]->{schema_file} }
    with 'App::Yath2::Role::DB::Backend';
}

my $dir = tempdir(CLEANUP => 1);
my $sql = "$dir/sqlite.sql";
open(my $fh, '>', $sql) or die $!;
print $fh <<'SQL';
-- minimal fixture schema
CREATE TABLE archives (
    archive_id   INTEGER PRIMARY KEY,
    archive_uuid TEXT NOT NULL UNIQUE
);
CREATE INDEX archives_uuid_idx ON archives(archive_uuid);
SQL
close $fh;

my $dbh = DBI->connect("dbi:SQLite:dbname=$dir/test.db", '', '', { RaiseError => 1, PrintError => 0 });

my $b = Test::Boot::Fake->new(dbh => $dbh, schema_file => $sql);

ok( !$b->_is_bootstrapped, 'not bootstrapped yet' );
$b->bootstrap_schema;
ok( $b->_is_bootstrapped, 'bootstrapped after run' );

# Idempotent.
my $ok = eval { $b->bootstrap_schema; 1 };
ok($ok, 'bootstrap_schema is idempotent');

# Comment stripping + statement split exercised.
my @rows = $dbh->selectrow_array("SELECT count(*) FROM archives");
is($rows[0], 0, 'archives table empty + queryable');

# Default identity preprocessor.
is( $b->preprocess_schema_sql('foo'), 'foo', 'preprocess identity by default' );

done_testing;

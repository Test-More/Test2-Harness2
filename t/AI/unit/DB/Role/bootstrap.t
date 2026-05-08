use Test2::V0;
use File::Temp qw/tempdir/;
use DBI;

use App::Yath2::Role::DB::Backend;

# Build a minimal consumer + a fixture share/schema/sqlite.sql.
{
    package Test::Boot::Fake;
    use Role::Tiny::With;
    for my $m (qw{
        services runs jobs tries last_try
        has_service has_run has_job has_try
        artifacts event events end_of_events reset
        extract archive insert
        archives archive_count has_archive scoped
        _archive_id_or_die _artifact_rows_for_archive
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

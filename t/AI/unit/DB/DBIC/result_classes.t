use Test2::V0;

use App::Yath2::DB::DBIC::Schema;

# One Result class per CREATE TABLE in share/schema/sqlite.sql.
# Names follow a singular CamelCase rule:
#   projects          -> Project
#   archives          -> Archive
#   runs              -> Run
#   services          -> Service
#   service_lifetimes -> ServiceLifetime
#   test_files        -> TestFile
#   jobs              -> Job
#   job_tries         -> JobTry
#   job_specs         -> JobSpec
#   subtests          -> Subtest
#   artifacts         -> Artifact
my %expected_table_for_source = (
    Project         => 'projects',
    Archive         => 'archives',
    Run             => 'runs',
    Service         => 'services',
    ServiceLifetime => 'service_lifetimes',
    TestFile        => 'test_files',
    Job             => 'jobs',
    JobTry          => 'job_tries',
    JobSpec         => 'job_specs',
    Subtest         => 'subtests',
    Artifact        => 'artifacts',
);

my $schema = App::Yath2::DB::DBIC::Schema->connect(
    sub { die "no real connection in this test" }
);

my @sources = sort $schema->sources;
is(
    \@sources,
    [sort keys %expected_table_for_source],
    "schema exposes one Result source per table"
);

for my $src (@sources) {
    subtest $src => sub {
        my $rs = $schema->resultset($src);
        ok( $rs, "resultset for $src loads" );

        my $rsrc = $rs->result_source;
        is(
            $rsrc->name,
            $expected_table_for_source{$src},
            "table name matches"
        );

        my @pk = $rsrc->primary_columns;
        ok( scalar(@pk), "$src has at least one primary key column" );

        # Every result class should also declare at least one column
        # beyond the primary key (otherwise the table is uninteresting).
        my @cols = $rsrc->columns;
        ok( scalar(@cols) > scalar(@pk),
            "$src has columns beyond the primary key (${\ scalar @cols} cols)" );
    };
}

done_testing;

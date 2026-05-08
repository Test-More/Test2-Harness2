use Test2::V0;
use Test2::Require::Module 'Role::Tiny';

ok( lives { require App::Yath2::Role::DB::Backend }, 'loads App::Yath2::Role::DB::Backend' )
    or diag $@;

ok( Role::Tiny->is_role('App::Yath2::Role::DB::Backend'),
    'is a Role::Tiny role' );

# Required methods declared. _archive_id_or_die +
# _artifact_rows_for_archive are role-level primitives consumers
# implement so the role can supply orchestration like list_files
# without poking at flavor-specific SQL or ResultSets.
my @required = sort qw{
    dbh flavor _archive_id_or_die
    services runs jobs tries last_try
    has_service has_run has_job has_try
    artifacts event events end_of_events reset
    extract archive insert
    archives archive_count has_archive scoped
    _artifact_rows_for_archive
};
# Concrete methods provided by the role:
my @provided = sort qw{
    bootstrap_schema preprocess_schema_sql schema_file _is_bootstrapped
    list_files _base_for_artifact_row _stem_for_artifact_row
};

# requires() introspection.
my $info = $Role::Tiny::INFO{'App::Yath2::Role::DB::Backend'} || {};
my %req = map { $_ => 1 } @{ $info->{requires} || [] };
is(\%req, { map { $_ => 1 } @required }, 'required method list matches');

# Provided method list contains the bootstrap helpers.
for my $m (@provided) {
    ok(App::Yath2::Role::DB::Backend->can($m), "role provides $m");
}

# A class consuming the role with all required stubs DOES the role.
{
    package Test::FakeBackend;
    use Role::Tiny::With;
    for my $m (qw{
        dbh flavor _archive_id_or_die
        services runs jobs tries last_try
        has_service has_run has_job has_try
        artifacts event events end_of_events reset
        extract archive insert
        archives archive_count has_archive scoped
        _artifact_rows_for_archive
    }) {
        no strict 'refs';
        *{$m} = sub { die "$m unimplemented" };
    }
    with 'App::Yath2::Role::DB::Backend';
    sub new { bless {}, shift }
}

ok( Test::FakeBackend->new->DOES('App::Yath2::Role::DB::Backend'),
    'fake backend consumes the role' );

done_testing;

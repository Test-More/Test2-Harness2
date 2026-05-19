use Test2::V0;
use Test2::Require::Module 'Role::Tiny';

ok( lives { require App::Yath2::Role::DB::Backend }, 'loads App::Yath2::Role::DB::Backend' )
    or diag $@;

ok( Role::Tiny->is_role('App::Yath2::Role::DB::Backend'),
    'is a Role::Tiny role' );

# Required methods are the row-level primitive contract App::Yath2::DB
# consumes. The Log-shape archive surface (event walker, list_files,
# artifacts factory, extract / archive / insert / save_artifact) lives
# entirely on App::Yath2::DB; backends never carry it.
my @required = sort qw{
    dbh flavor

    archive_rows archive_for_uuid archive_count archive_create mark_sealed

    run_rows service_rows job_rows try_rows

    ensure_run_row

    artifact_rows_for_archive artifact_row_for_scope artifact_payload
    artifact_create artifact_update artifact_event_count_for_archive

    job_spec_rows service_lifetime_rows subtest_rows
    job_spec_create service_lifetime_create subtest_create

    _count_rows _find_one_col _ensure_row
};

# Concrete methods provided by the role:
my @provided = sort qw{
    bootstrap_schema preprocess_schema_sql schema_file _is_bootstrapped
    _should_skip_schema_statement
    _base_for_artifact_row _stem_for_artifact_row _scope_where_clause

    _uuid_to_db _uuid_from_db
    _maybe_decode_json _maybe_encode_json _inflate_json_rows

    run_exists job_exists try_exists service_exists
    run_id_for_ord job_id_for_ord try_id_for_ord service_id_for_name
    ensure_project_row ensure_test_file_row
    ensure_service_row ensure_job_row ensure_job_try_row
};

# requires() introspection.
my $info = $Role::Tiny::INFO{'App::Yath2::Role::DB::Backend'} || {};
my %req = map { $_ => 1 } @{ $info->{requires} || [] };
is(\%req, { map { $_ => 1 } @required }, 'required method list matches');

# Provided method list contains the bootstrap + helper methods.
for my $m (@provided) {
    ok(App::Yath2::Role::DB::Backend->can($m), "role provides $m");
}

# A class consuming the role with all required stubs DOES the role.
{
    package Test::FakeBackend;
    use Role::Tiny::With;
    for my $m (@required) {
        no strict 'refs';
        *{$m} = sub { die "$m unimplemented" };
    }
    with 'App::Yath2::Role::DB::Backend';
    sub new { bless {}, shift }
}

ok( Test::FakeBackend->new->DOES('App::Yath2::Role::DB::Backend'),
    'fake backend consumes the role' );

done_testing;

use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

sub build_log_with_restarts {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    write_jsonl_zst("$src/services/harness/events.jsonl.zst", {ping => 1});

    write_jsonl_zst(
        "$src/services/harness/spec.jsonl.zst",
        {
            type         => 'Service',
            id           => 'harness',
            service_name => 'harness',
            role         => 'harness',
            started_at   => 1778112000,
            pid          => 12345,
            workdir      => '/tmp/some_workdir',
        },
    );

    write_jsonl_zst(
        "$src/services/harness/report.jsonl.zst",
        {
            type     => 'Service',
            id       => 'harness',
            ended_at => 1778112060,
            exit     => 1,
            times    => [1.0, 0.5, 0.1, 0.4],
        },
        {
            type     => 'Service',
            id       => 'harness',
            ended_at => 1778112120,
            exit     => 2,
            times    => [2.0, 1.0, 0.2, 0.8],
        },
        {
            type     => 'Service',
            id       => 'harness',
            ended_at => 1778112180,
            exit     => 0,
            times    => [3.0, 1.5, 0.3, 1.2],
        },
    );

    write_jsonl_zst("$src/runs/0/events.jsonl.zst",            {ping => 1});
    write_jsonl_zst("$src/runs/0/jobs/0/0/events.jsonl.zst",   {ping => 1});
    write_jsonl_zst("$src/runs/0/jobs/0/0/spec.jsonl.zst",
        {relative => 't/dummy.t'});

    return $src;
}

for_each_log_db_backend(sub {
    my ($backend) = @_;

    # Datetime columns are returned to consumers as hi-res unix epoch
    # floats; per-flavor parsing lives on $db->backend->db_parse_datetime.

    my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $db_path;
    my $db = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
    $db->bootstrap_schema;
    my $dbh = $db->dbh;

    my $src = build_log_with_restarts();
    my $aid = $db->insert(App::Yath2::Log->new(dir => $src));
    ok(defined $aid, 'insert() succeeded');

    my $svc = $dbh->selectrow_hashref(
        q{SELECT * FROM services WHERE archive_id = ? AND name = 'harness'},
        undef, $aid,
    );
    ok(defined $svc, 'services row for harness exists');
    is($svc->{role}, 'harness', 'services.role populated from spec row');

    my $sid = $svc->{service_id};

    my $rows = $dbh->selectall_arrayref(
        q{SELECT * FROM service_lifetimes WHERE service_id = ? ORDER BY lifetime_ord},
        { Slice => {} }, $sid,
    );
    is(scalar @$rows, 3, '3 service_lifetimes rows for harness');

    is($rows->[0]{lifetime_ord}, 1, 'lifetime_ord 1 first');
    is($rows->[1]{lifetime_ord}, 2, 'lifetime_ord 2 second');
    is($rows->[2]{lifetime_ord}, 3, 'lifetime_ord 3 third');

    is($db->backend->db_parse_datetime($rows->[0]{ended_at}), 1778112060, 'row 1 ended_at');
    is($db->backend->db_parse_datetime($rows->[1]{ended_at}), 1778112120, 'row 2 ended_at');
    is($db->backend->db_parse_datetime($rows->[2]{ended_at}), 1778112180, 'row 3 ended_at');

    is($rows->[0]{exit}, 1, 'row 1 exit');
    is($rows->[1]{exit}, 2, 'row 2 exit');
    is($rows->[2]{exit}, 0, 'row 3 exit');

    is($db->backend->db_parse_datetime($rows->[0]{started_at}), 1778112000,
        'row 1 started_at from spec');
    is($rows->[1]{started_at}, undef, 'row 2 started_at NULL (no spec)');
    is($rows->[2]{started_at}, undef, 'row 3 started_at NULL (no spec)');

    is($rows->[0]{status}, 'completed', 'row 1 status completed');
    is($rows->[1]{status}, 'completed', 'row 2 status completed');
    is($rows->[2]{status}, 'completed', 'row 3 status completed');

    is($rows->[0]{type}, 'Service', 'row 1 type from spec');
    is($rows->[0]{id},   'harness', 'row 1 id from spec');
    is($rows->[0]{service_name}, 'harness', 'row 1 service_name from spec');

    ok(defined $rows->[0]{spec_extras}, 'row 1 spec_extras populated');
    my $extras = decode_json($rows->[0]{spec_extras});
    is($extras->{pid},     12345,             'spec_extras.pid present');
    is($extras->{workdir}, '/tmp/some_workdir', 'spec_extras.workdir present');
    ok(exists $extras->{role}, 'role copy lands in spec_extras (also promoted to services.role)');
    ok(!exists $extras->{type},       'type was promoted (not in extras)');
    ok(!exists $extras->{started_at}, 'started_at was promoted (not in extras)');

    is($rows->[1]{spec_extras}, undef, 'row 2 spec_extras NULL');
    is($rows->[2]{spec_extras}, undef, 'row 3 spec_extras NULL');

    ok(defined $rows->[0]{state_extras}, 'row 1 state_extras populated');
    my $st_extras = decode_json($rows->[0]{state_extras});
    ok(exists $st_extras->{id},   'state_extras.id present');
    ok(exists $st_extras->{type}, 'state_extras.type present');
    ok(!exists $st_extras->{ended_at}, 'ended_at was promoted (not in state_extras)');
    ok(!exists $st_extras->{exit},     'exit was promoted (not in state_extras)');

    ok(defined $rows->[0]{times}, 'row 1 times populated');
    my $times = decode_json($rows->[0]{times});
    is($times, [1.0, 0.5, 0.1, 0.4], 'row 1 times from report');

    my $cols = $dbh->selectall_arrayref(q{PRAGMA table_info(services)}, { Slice => {} });
    my %col_names = map { $_->{name} => 1 } @$cols;
    ok(!exists $col_names{spec},   'services.spec column dropped');
    ok(!exists $col_names{state},  'services.state column dropped');
    ok(!exists $col_names{status}, 'services.status column dropped');
    ok( exists $col_names{role},   'services.role column present');
});

done_testing;

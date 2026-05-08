use Test2::V0;
use Test2::Require::Module 'DBD::Pg';
use Test2::Require::Module 'DBIx::QuickDB';
use Test2::Require::Module 'Test2::Tools::QuickDB';

use Test2::Tools::QuickDB;
use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_db_version get_quiet_db/;
for_each_db_version([qw/postgresql/], sub {
    skipall_unless_can_db(driver => 'PostgreSQL');

    use File::Temp qw/tempdir/;
    use File::Path qw/make_path/;
    use DBI ();

    use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
    use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
    use App::Yath2::Log;
    use App::Yath2::Log::Postgres;

    my $qdb = get_quiet_db({ driver => 'PostgreSQL' });
    {
    my $admin = DBI->connect(
        $qdb->connect_string('postgres'), undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1 },
    ) or die "connect: $DBI::errstr";
    $admin->do('CREATE DATABASE yath_log_test_specrep');
    $admin->disconnect;
    }
    my $dsn = $qdb->connect_string('yath_log_test_specrep');

    sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
    }

    sub build_log {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    write_jsonl_zst("$src/services/harness/events.jsonl.zst", {ping => 1});
    write_jsonl_zst("$src/services/harness/spec.jsonl.zst",
        {type => 'Service', id => 'harness'});

    write_jsonl_zst("$src/runs/0/events.jsonl.zst", {ping => 1});

    write_jsonl_zst(
        "$src/runs/0/spec.jsonl.zst",
        {
            started_at => '2026-05-07T00:00:00Z',
            times      => [1, 2, 3, 4],
            harness    => 'yath',
            name       => 'fancy run',
        },
    );

    write_jsonl_zst(
        "$src/runs/0/report.jsonl.zst",
        {
            ended_at     => '2026-05-07T00:01:00Z',
            exit         => 0,
            pass         => 1,
            total_jobs   => 2,
            passed_jobs  => 2,
            failed_jobs  => 0,
            aborted_jobs => 0,
            times        => [9, 8, 7, 6],
            child_times  => [0.5, 0.6, 0.7, 0.8],
            child_wall   => 1.234,
            git_status   => 'clean',
            host         => 'box.example',
            jobs         => [{job_id => 'x'}],
            subtests     => [{name => 'sub1', pass => 1}],
            services     => [{name => 'harness'}],
        },
    );

    write_jsonl_zst("$src/runs/0/jobs/0/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/spec.jsonl.zst",
        {
            relative   => 't/dummy.t',
            queued_at  => '2026-05-07T00:00:00.500Z',
            started_at => '2026-05-07T00:00:01Z',
            times      => [1, 2, 3, 4],
            comment    => 'a per-try note',
        },
    );
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/report.jsonl.zst",
        {
            ended_at        => '2026-05-07T00:00:02Z',
            exit            => 0,
            pass            => 1,
            pass_count      => 5,
            fail_count      => 0,
            assertion_count => 5,
            plan            => {count => 5},
            halt            => {reason => 'normal'},
            times           => [9, 8, 7, 6],
            child_times     => [0.1, 0.2, 0.3, 0.4],
            child_wall      => 0.5,
            note            => 'all good',
            subtests        => [
                {name => 'sub_a', pass => 1, count_pass => 3, count_fail => 0},
            ],
        },
    );

    return $src;
    }

    my $src = build_log();
    my $pg  = App::Yath2::Log::Postgres->new(dsn => $dsn);
    my $aid = $pg->insert(App::Yath2::Log->new(dir => $src));
    ok(defined $aid, 'insert() succeeded');

    my $dbh = $pg->dbh;

    # --- runs row ---

    my $run = $dbh->selectrow_hashref(
    q{SELECT * FROM runs WHERE archive_id = ? AND run_ord = 0},
    undef, $aid,
    );
    ok(defined $run, 'runs row exists');

    like($run->{started_at}, qr/2026-05-07.*00:00:00/, 'runs.started_at from spec');
    like($run->{ended_at},   qr/2026-05-07.*00:01:00/, 'runs.ended_at from report');
    is($run->{exit},         0, 'runs.exit from report');
    is($run->{total_jobs},   2, 'runs.total_jobs from report');

    # Postgres returns BOOLEAN as 't'/'f' / 1/0 depending on driver settings.
    ok($run->{pass}, 'runs.pass truthy from report');

    ok(defined $run->{times}, 'runs.times populated');
    is(decode_json($run->{times}), [9, 8, 7, 6], 'runs.times: report wins');

    ok(defined $run->{child_times}, 'runs.child_times populated');
    is(decode_json($run->{child_times}), [0.5, 0.6, 0.7, 0.8], 'runs.child_times');
    is($run->{child_wall} + 0, 1.234, 'runs.child_wall');

    ok(defined $run->{spec_extras}, 'runs.spec_extras populated');
    my $spec_x = decode_json($run->{spec_extras});
    is($spec_x->{harness}, 'yath',     'runs.spec_extras.harness present');
    is($spec_x->{name},    'fancy run', 'runs.spec_extras.name present');
    ok(!exists $spec_x->{started_at}, 'started_at not in spec_extras');
    ok(!exists $spec_x->{times},      'times not in spec_extras');
    ok(!exists $spec_x->{jobs},       'jobs aggregated (not in spec_extras)');

    ok(defined $run->{state_extras}, 'runs.state_extras populated');
    my $state_x = decode_json($run->{state_extras});
    is($state_x->{git_status}, 'clean', 'runs.state_extras.git_status present');
    is($state_x->{host}, 'box.example', 'runs.state_extras.host present');
    ok(!exists $state_x->{ended_at},  'ended_at not in state_extras');
    ok(!exists $state_x->{times},     'times not in state_extras');
    ok(!exists $state_x->{jobs},      'jobs aggregated (not in state_extras)');
    ok(!exists $state_x->{subtests},  'subtests aggregated (not in state_extras)');
    ok(!exists $state_x->{services},  'services aggregated (not in state_extras)');

    # Schema: legacy spec/state columns dropped; new ones present.
    my $columns = $dbh->selectall_arrayref(
    q{SELECT column_name FROM information_schema.columns
       WHERE table_name = 'runs'},
    { Slice => {} },
    );
    my %col_names = map { $_->{column_name} => 1 } @$columns;
    ok(!exists $col_names{spec},  'runs.spec column dropped');
    ok(!exists $col_names{state}, 'runs.state column dropped');
    ok( exists $col_names{times},        'runs.times present');
    ok( exists $col_names{child_times},  'runs.child_times present');
    ok( exists $col_names{child_wall},   'runs.child_wall present');
    ok( exists $col_names{spec_extras},  'runs.spec_extras present');
    ok( exists $col_names{state_extras}, 'runs.state_extras present');

    # --- job_tries row ---

    my $jt = $dbh->selectrow_hashref(q{
    SELECT jt.*
      FROM job_tries jt
      JOIN jobs      j ON j.job_id = jt.job_id
     WHERE j.archive_id = ?
    }, undef, $aid);
    ok(defined $jt, 'job_tries row exists');

    like($jt->{queued_at},  qr/2026-05-07.*00:00:00/, 'job_tries.queued_at from spec');
    like($jt->{started_at}, qr/2026-05-07.*00:00:01/, 'job_tries.started_at from spec');
    like($jt->{ended_at},   qr/2026-05-07.*00:00:02/, 'job_tries.ended_at from report');

    is($jt->{exit},            0, 'job_tries.exit');
    ok($jt->{pass},               'job_tries.pass truthy');
    is($jt->{pass_count},      5, 'job_tries.pass_count');
    is($jt->{fail_count},      0, 'job_tries.fail_count');
    is($jt->{assertion_count}, 5, 'job_tries.assertion_count');

    ok(defined $jt->{plan}, 'job_tries.plan populated');
    is(decode_json($jt->{plan}), {count => 5}, 'job_tries.plan JSON');
    ok(defined $jt->{halt}, 'job_tries.halt populated');
    is(decode_json($jt->{halt}), {reason => 'normal'}, 'job_tries.halt JSON');

    is(decode_json($jt->{times}),       [9, 8, 7, 6],          'job_tries.times');
    is(decode_json($jt->{child_times}), [0.1, 0.2, 0.3, 0.4],  'job_tries.child_times');
    is($jt->{child_wall} + 0, 0.5, 'job_tries.child_wall');

    my $jt_spec_x = decode_json($jt->{spec_extras});
    is($jt_spec_x->{comment}, 'a per-try note', 'job_tries.spec_extras.comment');

    my $jt_state_x = decode_json($jt->{state_extras});
    is($jt_state_x->{note}, 'all good', 'job_tries.state_extras.note');
    ok(!exists $jt_state_x->{subtests}, 'subtests aggregated (not in state_extras)');

    # Schema: legacy spec/state columns dropped; new ones present.
    my $jt_columns = $dbh->selectall_arrayref(
    q{SELECT column_name FROM information_schema.columns
       WHERE table_name = 'job_tries'},
    { Slice => {} },
    );
    my %jt_col_names = map { $_->{column_name} => 1 } @$jt_columns;
    ok(!exists $jt_col_names{spec},  'job_tries.spec column dropped');
    ok(!exists $jt_col_names{state}, 'job_tries.state column dropped');
    ok( exists $jt_col_names{queued_at},       'job_tries.queued_at present');
    ok( exists $jt_col_names{pass_count},      'job_tries.pass_count present');
    ok( exists $jt_col_names{fail_count},      'job_tries.fail_count present');
    ok( exists $jt_col_names{assertion_count}, 'job_tries.assertion_count present');
    ok( exists $jt_col_names{plan},            'job_tries.plan present');
    ok( exists $jt_col_names{halt},            'job_tries.halt present');
    ok( exists $jt_col_names{times},           'job_tries.times present');
    ok( exists $jt_col_names{child_times},     'job_tries.child_times present');
    ok( exists $jt_col_names{child_wall},      'job_tries.child_wall present');
    ok( exists $jt_col_names{spec_extras},     'job_tries.spec_extras present');
    ok( exists $jt_col_names{state_extras},    'job_tries.state_extras present');

});

done_testing;

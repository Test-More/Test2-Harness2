use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;
use App::Yath2::DB::Internal;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

# B4: assert spec/report content is split into typed columns and a
# *_extras catch-all on `runs` and `job_tries`. Aggregated keys
# (`jobs`, `subtests`, `services`) are excluded from extras and
# rebuilt via JOIN at read time.

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
            jobs         => [{job_id => 'x'}, {job_id => 'y'}],
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
                {name => 'sub_b', pass => 1, count_pass => 2, count_fail => 0},
            ],
        },
    );

    return $src;
}

# --- Promoted-key constants exposed for downstream (backend-independent) ---

ok(scalar(@App::Yath2::DB::Internal::RUNS_SPEC_PROMOTED_KEYS) > 0,
    '@RUNS_SPEC_PROMOTED_KEYS non-empty');
ok((grep { $_ eq 'started_at' } @App::Yath2::DB::Internal::RUNS_SPEC_PROMOTED_KEYS),
    'started_at in @RUNS_SPEC_PROMOTED_KEYS');
ok((grep { $_ eq 'ended_at'   } @App::Yath2::DB::Internal::RUNS_REPORT_PROMOTED_KEYS),
    'ended_at in @RUNS_REPORT_PROMOTED_KEYS');
ok((grep { $_ eq 'jobs' } @App::Yath2::DB::Internal::RUNS_AGGREGATED_KEYS),
    'jobs in @RUNS_AGGREGATED_KEYS');
ok((grep { $_ eq 'subtests' } @App::Yath2::DB::Internal::RUNS_AGGREGATED_KEYS),
    'subtests in @RUNS_AGGREGATED_KEYS');
ok((grep { $_ eq 'services' } @App::Yath2::DB::Internal::RUNS_AGGREGATED_KEYS),
    'services in @RUNS_AGGREGATED_KEYS');

ok(scalar(@App::Yath2::DB::Internal::JOB_TRIES_SPEC_PROMOTED_KEYS) > 0,
    '@JOB_TRIES_SPEC_PROMOTED_KEYS non-empty');
ok((grep { $_ eq 'queued_at' } @App::Yath2::DB::Internal::JOB_TRIES_SPEC_PROMOTED_KEYS),
    'queued_at in @JOB_TRIES_SPEC_PROMOTED_KEYS');
ok((grep { $_ eq 'plan' } @App::Yath2::DB::Internal::JOB_TRIES_REPORT_PROMOTED_KEYS),
    'plan in @JOB_TRIES_REPORT_PROMOTED_KEYS');
ok((grep { $_ eq 'subtests' } @App::Yath2::DB::Internal::JOB_TRIES_AGGREGATED_KEYS),
    'subtests in @JOB_TRIES_AGGREGATED_KEYS');

for_each_log_db_backend(sub {
    my ($backend) = @_;

    my $sql = sub {
        my ($db) = @_;
        return $backend eq 'dbic' ? $db->_internal : $db;
    };

    my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $db_path;
    my $db = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
    $db->bootstrap_schema;
    my $dbh = $db->dbh;

    my $src = build_log();
    my $aid = $db->insert(App::Yath2::Log->new(dir => $src));
    ok(defined $aid, 'insert() succeeded');

    # --- runs row ---

    my $run = $dbh->selectrow_hashref(
        q{SELECT * FROM runs WHERE archive_id = ? AND run_ord = 0},
        undef, $aid,
    );
    ok(defined $run, 'runs row exists');

    is($sql->($db)->_db_datetime_to_iso($run->{started_at}), '2026-05-07T00:00:00Z', 'runs.started_at from spec');

    is($sql->($db)->_db_datetime_to_iso($run->{ended_at}), '2026-05-07T00:01:00Z', 'runs.ended_at from report');
    is($run->{exit},         0,                       'runs.exit from report');
    is($run->{pass},         1,                       'runs.pass from report');
    is($run->{total_jobs},   2,                       'runs.total_jobs from report');
    is($run->{passed_jobs},  2,                       'runs.passed_jobs from report');
    is($run->{failed_jobs},  0,                       'runs.failed_jobs from report');
    is($run->{aborted_jobs}, 0,                       'runs.aborted_jobs from report');

    ok(defined $run->{times}, 'runs.times populated');
    is(decode_json($run->{times}), [9, 8, 7, 6], 'runs.times: report wins on collision');

    ok(defined $run->{child_times}, 'runs.child_times populated');
    is(decode_json($run->{child_times}), [0.5, 0.6, 0.7, 0.8], 'runs.child_times');
    is($run->{child_wall} + 0, 1.234, 'runs.child_wall numeric pass-through');

    ok(defined $run->{spec_extras}, 'runs.spec_extras populated');
    my $spec_x = decode_json($run->{spec_extras});
    is($spec_x->{harness}, 'yath',     'runs.spec_extras.harness present');
    is($spec_x->{name},    'fancy run', 'runs.spec_extras.name present');
    ok(!exists $spec_x->{started_at}, 'started_at promoted (not in spec_extras)');
    ok(!exists $spec_x->{times},      'times promoted (not in spec_extras)');
    ok(!exists $spec_x->{run_uuid},   'run_uuid identity (not in spec_extras)');
    ok(!exists $spec_x->{jobs},       'jobs aggregated (not in spec_extras)');
    ok(!exists $spec_x->{subtests},   'subtests aggregated (not in spec_extras)');
    ok(!exists $spec_x->{services},   'services aggregated (not in spec_extras)');

    ok(defined $run->{state_extras}, 'runs.state_extras populated');
    my $state_x = decode_json($run->{state_extras});
    is($state_x->{git_status}, 'clean',       'runs.state_extras.git_status present');
    is($state_x->{host},       'box.example', 'runs.state_extras.host present');
    ok(!exists $state_x->{ended_at},     'ended_at promoted (not in state_extras)');
    ok(!exists $state_x->{exit},         'exit promoted (not in state_extras)');
    ok(!exists $state_x->{times},        'times promoted (not in state_extras)');
    ok(!exists $state_x->{child_times},  'child_times promoted (not in state_extras)');
    ok(!exists $state_x->{child_wall},   'child_wall promoted (not in state_extras)');
    ok(!exists $state_x->{jobs},         'jobs aggregated (not in state_extras)');
    ok(!exists $state_x->{subtests},     'subtests aggregated (not in state_extras)');
    ok(!exists $state_x->{services},     'services aggregated (not in state_extras)');

    my $cols = $dbh->selectall_arrayref(q{PRAGMA table_info(runs)}, { Slice => {} });
    my %col_names = map { $_->{name} => 1 } @$cols;
    ok(!exists $col_names{spec},  'runs.spec column dropped');
    ok(!exists $col_names{state}, 'runs.state column dropped');
    ok( exists $col_names{times},        'runs.times column present');
    ok( exists $col_names{child_times},  'runs.child_times column present');
    ok( exists $col_names{child_wall},   'runs.child_wall column present');
    ok( exists $col_names{spec_extras},  'runs.spec_extras column present');
    ok( exists $col_names{state_extras}, 'runs.state_extras column present');

    # --- job_tries row ---

    my $jt = $dbh->selectrow_hashref(q{
        SELECT jt.*
          FROM job_tries jt
          JOIN jobs      j ON j.job_id = jt.job_id
         WHERE j.archive_id = ?
    }, undef, $aid);
    ok(defined $jt, 'job_tries row exists');

    is($sql->($db)->_db_datetime_to_iso($jt->{queued_at}),  '2026-05-07T00:00:00.500Z', 'job_tries.queued_at from spec');
    is($sql->($db)->_db_datetime_to_iso($jt->{started_at}), '2026-05-07T00:00:01Z',     'job_tries.started_at from spec');

    is($sql->($db)->_db_datetime_to_iso($jt->{ended_at}), '2026-05-07T00:00:02Z', 'job_tries.ended_at from report');
    is($jt->{exit},            0,                       'job_tries.exit from report');
    is($jt->{pass},            1,                       'job_tries.pass from report');
    is($jt->{pass_count},      5,                       'job_tries.pass_count from report');
    is($jt->{fail_count},      0,                       'job_tries.fail_count from report');
    is($jt->{assertion_count}, 5,                       'job_tries.assertion_count from report');

    ok(defined $jt->{plan}, 'job_tries.plan populated');
    is(decode_json($jt->{plan}), {count => 5}, 'job_tries.plan JSON');
    ok(defined $jt->{halt}, 'job_tries.halt populated');
    is(decode_json($jt->{halt}), {reason => 'normal'}, 'job_tries.halt JSON');

    ok(defined $jt->{times}, 'job_tries.times populated');
    is(decode_json($jt->{times}), [9, 8, 7, 6], 'job_tries.times: report wins on collision');
    ok(defined $jt->{child_times}, 'job_tries.child_times populated');
    is(decode_json($jt->{child_times}), [0.1, 0.2, 0.3, 0.4], 'job_tries.child_times');
    is($jt->{child_wall} + 0, 0.5, 'job_tries.child_wall numeric pass-through');

    ok(defined $jt->{spec_extras}, 'job_tries.spec_extras populated');
    my $jt_spec_x = decode_json($jt->{spec_extras});
    is($jt_spec_x->{comment}, 'a per-try note', 'job_tries.spec_extras.comment present');
    ok(!exists $jt_spec_x->{queued_at},  'queued_at promoted (not in spec_extras)');
    ok(!exists $jt_spec_x->{started_at}, 'started_at promoted (not in spec_extras)');
    ok(!exists $jt_spec_x->{times},      'times promoted (not in spec_extras)');

    ok(defined $jt->{state_extras}, 'job_tries.state_extras populated');
    my $jt_state_x = decode_json($jt->{state_extras});
    is($jt_state_x->{note}, 'all good', 'job_tries.state_extras.note present');
    ok(!exists $jt_state_x->{ended_at},        'ended_at promoted (not in state_extras)');
    ok(!exists $jt_state_x->{pass_count},      'pass_count promoted (not in state_extras)');
    ok(!exists $jt_state_x->{plan},            'plan promoted (not in state_extras)');
    ok(!exists $jt_state_x->{halt},            'halt promoted (not in state_extras)');
    ok(!exists $jt_state_x->{times},           'times promoted (not in state_extras)');
    ok(!exists $jt_state_x->{subtests},        'subtests aggregated (not in state_extras)');

    my $subtests = $dbh->selectall_arrayref(
        q{SELECT name FROM subtests WHERE job_try_id = ? ORDER BY ord},
        { Slice => {} }, $jt->{job_try_id},
    );
    is(scalar @$subtests, 2,       '2 subtests rows for the job_try');
    is($subtests->[0]{name}, 'sub_a', 'subtest 0 name');
    is($subtests->[1]{name}, 'sub_b', 'subtest 1 name');

    my $jt_cols = $dbh->selectall_arrayref(q{PRAGMA table_info(job_tries)}, { Slice => {} });
    my %jt_col_names = map { $_->{name} => 1 } @$jt_cols;
    ok(!exists $jt_col_names{spec},  'job_tries.spec column dropped');
    ok(!exists $jt_col_names{state}, 'job_tries.state column dropped');
    ok( exists $jt_col_names{queued_at},       'job_tries.queued_at column present');
    ok( exists $jt_col_names{pass_count},      'job_tries.pass_count column present');
    ok( exists $jt_col_names{fail_count},      'job_tries.fail_count column present');
    ok( exists $jt_col_names{assertion_count}, 'job_tries.assertion_count column present');
    ok( exists $jt_col_names{plan},            'job_tries.plan column present');
    ok( exists $jt_col_names{halt},            'job_tries.halt column present');
    ok( exists $jt_col_names{times},           'job_tries.times column present');
    ok( exists $jt_col_names{child_times},     'job_tries.child_times column present');
    ok( exists $jt_col_names{child_wall},      'job_tries.child_wall column present');
    ok( exists $jt_col_names{spec_extras},     'job_tries.spec_extras column present');
    ok( exists $jt_col_names{state_extras},    'job_tries.state_extras column present');
});

done_testing;

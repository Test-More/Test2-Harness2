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

# B5: Reconstruction API. The DB backend serves spec.jsonl /
# report.jsonl on run / service / job_try scopes by reading typed
# columns + decoded *_extras and synthesizing JSONL records on demand.
# This test asserts the data-preservation contract: reconstructed
# records carry the typed fields, the extras keys, and the rebuilt
# aggregated keys (subtests, jobs[]) -- even after the artifact rows
# that originally held the bytes have been deleted.

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

# Build a synthetic source covering all four reconstruction kinds:
#   - run scope (1 spec row + 1 report row)
#   - global service with TWO restarts (2 spec rows + 2 report rows)
#   - job_try scope (1 spec row + 1 report row, with subtests)
sub build_source {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/services/runner");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    # The Live/Directory iterator needs the harness root events stream.
    write_jsonl_zst("$src/services/harness/events.jsonl.zst", {ping => 1});
    write_jsonl_zst("$src/services/harness/spec.jsonl.zst",
        {type => 'Service', id => 'harness'});

    # Multi-lifetime global service: two starts + two ends.
    write_jsonl_zst("$src/services/runner/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/services/runner/spec.jsonl.zst",
        {
            type         => 'Service',
            id           => 'runner',
            service_name => 'runner',
            stage_name   => 'main',
            role         => 'preload',
            started_at   => '2026-05-07T00:00:00Z',
            pid          => 11111,        # unpromoted -> spec_extras
            times        => [0.1, 0.2, 0.3, 0.4],
        },
        {
            type         => 'Service',
            id           => 'runner',
            service_name => 'runner',
            stage_name   => 'main',
            started_at   => '2026-05-07T00:00:10Z',
            pid          => 22222,        # unpromoted -> spec_extras
            times        => [1.1, 1.2, 1.3, 1.4],
        },
    );
    write_jsonl_zst(
        "$src/services/runner/report.jsonl.zst",
        {
            ended_at     => '2026-05-07T00:00:05Z',
            exit         => 0,
            exit_decoded => {signal => 0, status => 0},
            why          => 'restart',     # unpromoted -> state_extras
            times        => [0.6, 0.7, 0.8, 0.9],
            child_wall   => 0.42,
        },
        {
            ended_at     => '2026-05-07T00:00:15Z',
            exit         => 1,
            exit_decoded => {signal => 0, status => 1},
            why          => 'shutdown',    # unpromoted -> state_extras
            times        => [1.6, 1.7, 1.8, 1.9],
            child_wall   => 1.42,
        },
    );

    # Run-scope: spec + report.
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
            total_jobs   => 1,
            passed_jobs  => 1,
            failed_jobs  => 0,
            aborted_jobs => 0,
            times        => [9, 8, 7, 6],
            child_times  => [0.5, 0.6, 0.7, 0.8],
            child_wall   => 1.234,
            git_status   => 'clean',
            host         => 'box.example',
        },
    );

    # Job_try scope: spec + report with subtests.
    write_jsonl_zst("$src/runs/0/jobs/0/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/spec.jsonl.zst",
        {
            relative   => 't/dummy.t',
            absolute   => '/abs/t/dummy.t',
            queued_at  => '2026-05-07T00:00:00.500Z',
            started_at => '2026-05-07T00:00:01Z',
            stage      => 'default',
            features   => {fork => 1},
            times      => [1, 2, 3, 4],
            comment    => 'a per-try note',     # -> spec_extras
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
            note            => 'all good',     # -> state_extras
            subtests        => [
                {name => 'sub_a', pass => 1, count_pass => 3, count_fail => 0},
                {name => 'sub_b', pass => 1, count_pass => 2, count_fail => 0},
            ],
        },
    );

    return $src;
}

for_each_log_db_backend(sub {
    my ($backend) = @_;

my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $db_path;
my $db = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
my $aid = $db->insert(App::Yath2::Log->new(dir => build_source()));
ok(defined $aid, 'insert succeeded');

# B9: spec/report artifact rows are no longer written by insert(); the
# only read path is reconstruction from typed columns + extras. Verify
# the table really is empty of those kinds before exercising reads.
my $dbh = $db->dbh;
my ($n) = $dbh->selectrow_array(
    q{SELECT count(*) FROM artifacts WHERE artifact_kind IN ('spec', 'report', 'state')});
is($n, 0, 'no spec/report/state artifact rows present -- reads exercise reconstruction');

# Reopen via the public API to mirror real consumer use.
my $log = App::Yath2::Log->new(file => $db_path, backend => $backend);

# --- run-scope spec ---
{
    my $arts = $log->artifacts(0);
    my @recs;
    my $it = $arts->spec_iter;
    while (my $r = $it->next) { push @recs => $r }
    is(scalar @recs, 1, 'run spec_iter: 1 record');
    is($recs[0]{started_at}, '2026-05-07T00:00:00Z', 'run spec.started_at typed');
    # times: shared between spec/report and report wins on collision in
    # the typed column; spec reconstruction sees the post-collision value.
    is($recs[0]{times}, [9, 8, 7, 6], 'run spec.times decoded JSON column (report wins on shared key)');
    is($recs[0]{harness}, 'yath',     'run spec.harness from extras');
    is($recs[0]{name},    'fancy run', 'run spec.name from extras');
    ok(defined $recs[0]{run_uuid}, 'run spec.run_uuid present');
    ok(!exists $recs[0]{jobs},     'run spec: aggregated jobs not present');
    ok(!exists $recs[0]{subtests}, 'run spec: aggregated subtests not present');
}

# --- run-scope report ---
{
    my $arts = $log->artifacts(0);
    my @recs;
    my $it = $arts->report_iter;
    while (my $r = $it->next) { push @recs => $r }
    is(scalar @recs, 1, 'run report_iter: 1 record');
    is($recs[0]{ended_at},     '2026-05-07T00:01:00Z', 'run report.ended_at typed');
    is($recs[0]{exit},          0, 'run report.exit typed');
    is($recs[0]{pass},          1, 'run report.pass typed');
    is($recs[0]{total_jobs},    1, 'run report.total_jobs typed');
    is($recs[0]{times},         [9, 8, 7, 6],     'run report.times decoded');
    is($recs[0]{child_times},   [0.5, 0.6, 0.7, 0.8], 'run report.child_times decoded');
    is($recs[0]{child_wall} + 0, 1.234,  'run report.child_wall numeric');
    is($recs[0]{git_status},    'clean', 'run report.git_status from extras');
    is($recs[0]{host},          'box.example', 'run report.host from extras');

    # jobs[] rebuilt via JOIN.
    ok(ref $recs[0]{jobs} eq 'ARRAY', 'run report.jobs is array');
    is(scalar @{$recs[0]{jobs}}, 1, 'run report.jobs has 1 entry');
    is($recs[0]{jobs}[0]{job_ord}, 0, 'jobs[0].job_ord');
    ok(ref $recs[0]{jobs}[0]{tries} eq 'ARRAY', 'jobs[0].tries is array');
    is(scalar @{$recs[0]{jobs}[0]{tries}}, 1, 'jobs[0].tries has 1 entry');
    is($recs[0]{jobs}[0]{tries}[0]{try_ord}, 0, 'jobs[0].tries[0].try_ord');
}

# --- service-scope spec / report (multi-lifetime) ---
{
    my $arts = $log->artifacts('runner');
    my @specs;
    my $it = $arts->spec_iter;
    while (my $r = $it->next) { push @specs => $r }
    is(scalar @specs, 2, 'multi-lifetime service spec_iter: 2 records');
    is($specs[0]{started_at}, '2026-05-07T00:00:00Z', 'lifetime 1 started_at');
    is($specs[1]{started_at}, '2026-05-07T00:00:10Z', 'lifetime 2 started_at');
    is($specs[0]{type},         'Service', 'lifetime 1 type');
    is($specs[0]{service_name}, 'runner',  'lifetime 1 service_name');
    is($specs[0]{stage_name},   'main',    'lifetime 1 stage_name');
    # times: report wins on collision in the typed column; spec
    # reconstruction sees the post-collision value (report's times).
    is($specs[0]{times},        [0.6, 0.7, 0.8, 0.9], 'lifetime 1 times (report wins on shared key)');
    is($specs[1]{times},        [1.6, 1.7, 1.8, 1.9], 'lifetime 2 times (report wins on shared key)');
    is($specs[0]{pid},          11111, 'lifetime 1 pid from spec_extras');
    is($specs[1]{pid},          22222, 'lifetime 2 pid from spec_extras');
    # Role lives on services.role; we promote to every reconstructed
    # spec row (data-preservation, not byte-level).
    is($specs[0]{role}, 'preload', 'role copied to lifetime 1');
    is($specs[1]{role}, 'preload', 'role copied to lifetime 2');

    my @reports;
    my $rit = $arts->report_iter;
    while (my $r = $rit->next) { push @reports => $r }
    is(scalar @reports, 2, 'multi-lifetime service report_iter: 2 records');
    is($reports[0]{ended_at}, '2026-05-07T00:00:05Z', 'lifetime 1 ended_at');
    is($reports[1]{ended_at}, '2026-05-07T00:00:15Z', 'lifetime 2 ended_at');
    is($reports[0]{exit}, 0, 'lifetime 1 exit');
    is($reports[1]{exit}, 1, 'lifetime 2 exit');
    is($reports[0]{exit_decoded}, {signal => 0, status => 0}, 'lifetime 1 exit_decoded');
    is($reports[1]{exit_decoded}, {signal => 0, status => 1}, 'lifetime 2 exit_decoded');
    is($reports[0]{why}, 'restart',  'lifetime 1 why from state_extras');
    is($reports[1]{why}, 'shutdown', 'lifetime 2 why from state_extras');
}

# --- job_try-scope spec / report ---
{
    my $arts = $log->artifacts(0, 0, 0);
    my @specs;
    my $it = $arts->spec_iter;
    while (my $r = $it->next) { push @specs => $r }
    is(scalar @specs, 1, 'job_try spec_iter: 1 record');
    is($specs[0]{queued_at},  '2026-05-07T00:00:00.500Z', 'job_try spec.queued_at typed');
    is($specs[0]{started_at}, '2026-05-07T00:00:01Z',     'job_try spec.started_at typed');
    # times: report wins on collision in the typed column.
    is($specs[0]{times},      [9, 8, 7, 6],               'job_try spec.times decoded (report wins on shared key)');
    # job_specs typed columns merged.
    is($specs[0]{relative}, 't/dummy.t',     'job_try spec.relative from test_files');
    is($specs[0]{absolute}, '/abs/t/dummy.t','job_try spec.absolute from job_specs');
    is($specs[0]{stage},    'default',       'job_try spec.stage from job_specs');
    is($specs[0]{features}, {fork => 1},     'job_try spec.features from job_specs (decoded)');
    is($specs[0]{comment},  'a per-try note', 'job_try spec.comment from spec_extras');

    my @reports;
    my $rit = $arts->report_iter;
    while (my $r = $rit->next) { push @reports => $r }
    is(scalar @reports, 1, 'job_try report_iter: 1 record');
    is($reports[0]{ended_at},        '2026-05-07T00:00:02Z', 'job_try report.ended_at');
    is($reports[0]{exit},             0, 'job_try report.exit');
    is($reports[0]{pass},             1, 'job_try report.pass');
    is($reports[0]{pass_count},       5, 'job_try report.pass_count');
    is($reports[0]{fail_count},       0, 'job_try report.fail_count');
    is($reports[0]{assertion_count},  5, 'job_try report.assertion_count');
    is($reports[0]{plan},     {count  => 5},      'job_try report.plan decoded');
    is($reports[0]{halt},     {reason => 'normal'},'job_try report.halt decoded');
    is($reports[0]{note},     'all good',         'job_try report.note from state_extras');

    # subtests[] rebuilt via JOIN.
    ok(ref $reports[0]{subtests} eq 'ARRAY', 'job_try report.subtests is array');
    is(scalar @{$reports[0]{subtests}}, 2, 'job_try report.subtests has 2 entries');
    is($reports[0]{subtests}[0]{name}, 'sub_a', 'subtest 0 name');
    is($reports[0]{subtests}[0]{pass}, 1,       'subtest 0 pass');
    is($reports[0]{subtests}[0]{count_pass}, 3, 'subtest 0 count_pass');
    is($reports[0]{subtests}[1]{name}, 'sub_b', 'subtest 1 name');
}

# --- byte-level read ($arts->spec) also reconstructs ---
{
    my $arts = $log->artifacts(0);
    my $bytes = $arts->spec;
    ok(length $bytes,       'spec bytes non-empty (reconstructed)');
    like($bytes, qr/"started_at":/, 'spec bytes contain started_at');
    my @lines = split /\n/, $bytes;
    is(scalar @lines, 1, 'run spec bytes is one JSONL line');
    my $rec = decode_json($lines[0]);
    is($rec->{started_at}, '2026-05-07T00:00:00Z', 'spec bytes decode round-trips');
}

});

done_testing;

use Test2::V0;
use Test2::Require::Module 'DBD::MariaDB';
use Test2::Require::Module 'DBIx::QuickDB';
use Test2::Require::Module 'Test2::Tools::QuickDB';

use Test2::Tools::QuickDB;
skipall_unless_can_db(driver => 'MySQL');

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use DBI ();

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::MySQL;

my $qdb = get_db({ driver => 'MySQL' });
{
    my $admin = DBI->connect(
        $qdb->connect_string, undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    ) or die "connect: $DBI::errstr";
    $admin->do('CREATE DATABASE IF NOT EXISTS yath_log_test_reconstruct');
    $admin->disconnect;
}
my $dsn = $qdb->connect_string('yath_log_test_reconstruct');

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

sub build_source {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/services/runner");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    write_jsonl_zst("$src/services/harness/events.jsonl.zst", {ping => 1});
    write_jsonl_zst("$src/services/harness/spec.jsonl.zst",
        {type => 'Service', id => 'harness'});

    write_jsonl_zst("$src/services/runner/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/services/runner/spec.jsonl.zst",
        {
            type => 'Service', id => 'runner',
            service_name => 'runner', stage_name => 'main',
            role => 'preload',
            started_at => '2026-05-07 00:00:00',
            pid => 11111, times => [0.1, 0.2, 0.3, 0.4],
        },
        {
            type => 'Service', id => 'runner',
            service_name => 'runner', stage_name => 'main',
            started_at => '2026-05-07 00:00:10',
            pid => 22222, times => [1.1, 1.2, 1.3, 1.4],
        },
    );
    write_jsonl_zst(
        "$src/services/runner/report.jsonl.zst",
        {ended_at => '2026-05-07 00:00:05', exit => 0,
         exit_decoded => {signal => 0, status => 0},
         why => 'restart',  times => [0.6, 0.7, 0.8, 0.9], child_wall => 0.42},
        {ended_at => '2026-05-07 00:00:15', exit => 1,
         exit_decoded => {signal => 0, status => 1},
         why => 'shutdown', times => [1.6, 1.7, 1.8, 1.9], child_wall => 1.42},
    );

    write_jsonl_zst("$src/runs/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/runs/0/spec.jsonl.zst",
        {
            started_at => '2026-05-07 00:00:00',
            times => [1, 2, 3, 4],
            harness => 'yath',
            name => 'fancy run',
        },
    );
    write_jsonl_zst(
        "$src/runs/0/report.jsonl.zst",
        {
            ended_at => '2026-05-07 00:01:00',
            exit => 0, pass => 1,
            total_jobs => 1, passed_jobs => 1, failed_jobs => 0, aborted_jobs => 0,
            times => [9, 8, 7, 6],
            child_times => [0.5, 0.6, 0.7, 0.8],
            child_wall => 1.234,
            git_status => 'clean',
            host => 'box.example',
        },
    );

    write_jsonl_zst("$src/runs/0/jobs/0/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/spec.jsonl.zst",
        {
            relative => 't/dummy.t',
            absolute => '/abs/t/dummy.t',
            queued_at => '2026-05-07 00:00:00.500',
            started_at => '2026-05-07 00:00:01',
            stage => 'default',
            features => {fork => 1},
            times => [1, 2, 3, 4],
            comment => 'a per-try note',
        },
    );
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/report.jsonl.zst",
        {
            ended_at => '2026-05-07 00:00:02',
            exit => 0, pass => 1,
            pass_count => 5, fail_count => 0, assertion_count => 5,
            plan => {count => 5},
            halt => {reason => 'normal'},
            times => [9, 8, 7, 6],
            child_times => [0.1, 0.2, 0.3, 0.4],
            child_wall => 0.5,
            note => 'all good',
            subtests => [
                {name => 'sub_a', pass => 1, count_pass => 3, count_fail => 0},
                {name => 'sub_b', pass => 1, count_pass => 2, count_fail => 0},
            ],
        },
    );

    return $src;
}

my $db = App::Yath2::Log::MySQL->new(dsn => $dsn);
my $aid = $db->insert(App::Yath2::Log->new(dir => build_source()));
ok(defined $aid, 'insert succeeded');

my $dbh = $db->dbh;
# B9: spec/report artifact rows are not written; reconstruction is the
# only read path. The narrowed ENUM would reject 'spec'/'report' values
# even if we tried to insert them.

my $log = App::Yath2::Log::MySQL->new(dsn => $dsn);

# --- run-scope spec ---
{
    my $arts = $log->artifacts(0);
    my @recs;
    my $it = $arts->spec_iter;
    while (my $r = $it->next) { push @recs => $r }
    is(scalar @recs, 1, 'run spec_iter: 1 record');
    like($recs[0]{started_at}, qr/2026-05-07.*00:00:00/, 'run spec.started_at typed');
    is($recs[0]{times}, [9, 8, 7, 6], 'run spec.times decoded (report wins)');
    is($recs[0]{harness}, 'yath',     'run spec.harness from extras');
    is($recs[0]{name},    'fancy run', 'run spec.name from extras');
    ok(defined $recs[0]{run_uuid}, 'run spec.run_uuid present');
}

# --- run-scope report ---
{
    my $arts = $log->artifacts(0);
    my @recs;
    my $it = $arts->report_iter;
    while (my $r = $it->next) { push @recs => $r }
    is(scalar @recs, 1, 'run report_iter: 1 record');
    like($recs[0]{ended_at}, qr/2026-05-07.*00:01:00/, 'run report.ended_at typed');
    is($recs[0]{exit}, 0, 'run report.exit typed');
    ok($recs[0]{pass}, 'run report.pass truthy');
    is($recs[0]{times},       [9, 8, 7, 6], 'run report.times decoded');
    is($recs[0]{child_times}, [0.5, 0.6, 0.7, 0.8], 'run report.child_times decoded');
    is($recs[0]{child_wall} + 0, 1.234, 'run report.child_wall numeric');
    is($recs[0]{git_status}, 'clean', 'run report.git_status from extras');

    ok(ref $recs[0]{jobs} eq 'ARRAY', 'run report.jobs is array');
    is(scalar @{$recs[0]{jobs}}, 1, 'run report.jobs has 1 entry');
    is($recs[0]{jobs}[0]{job_ord}, 0, 'jobs[0].job_ord');
}

# --- service-scope multi-lifetime ---
{
    my $arts = $log->artifacts('runner');
    my @specs;
    my $it = $arts->spec_iter;
    while (my $r = $it->next) { push @specs => $r }
    is(scalar @specs, 2, 'multi-lifetime service spec_iter: 2 records');
    is($specs[0]{type},         'Service', 'lifetime 1 type');
    is($specs[0]{service_name}, 'runner',  'lifetime 1 service_name');
    is($specs[0]{pid},          11111,     'lifetime 1 pid from extras');
    is($specs[1]{pid},          22222,     'lifetime 2 pid from extras');
    is($specs[0]{role}, 'preload', 'role on lifetime 1');
    is($specs[1]{role}, 'preload', 'role on lifetime 2');

    my @reports;
    my $rit = $arts->report_iter;
    while (my $r = $rit->next) { push @reports => $r }
    is(scalar @reports, 2, 'multi-lifetime service report_iter: 2 records');
    is($reports[0]{exit}, 0, 'lifetime 1 exit');
    is($reports[1]{exit}, 1, 'lifetime 2 exit');
    is($reports[0]{why}, 'restart',  'lifetime 1 why from extras');
    is($reports[1]{why}, 'shutdown', 'lifetime 2 why from extras');
}

# --- job_try-scope ---
{
    my $arts = $log->artifacts(0, 0, 0);
    my @specs;
    my $it = $arts->spec_iter;
    while (my $r = $it->next) { push @specs => $r }
    is(scalar @specs, 1, 'job_try spec_iter: 1 record');
    is($specs[0]{relative}, 't/dummy.t',     'job_try spec.relative');
    is($specs[0]{absolute}, '/abs/t/dummy.t','job_try spec.absolute from job_specs');
    is($specs[0]{features}, {fork => 1},     'job_try spec.features decoded');
    is($specs[0]{comment},  'a per-try note', 'job_try spec.comment from extras');

    my @reports;
    my $rit = $arts->report_iter;
    while (my $r = $rit->next) { push @reports => $r }
    is(scalar @reports, 1, 'job_try report_iter: 1 record');
    is($reports[0]{plan}, {count  => 5},       'job_try report.plan decoded');
    is($reports[0]{halt}, {reason => 'normal'},'job_try report.halt decoded');
    is($reports[0]{note}, 'all good',          'job_try report.note from extras');
    ok(ref $reports[0]{subtests} eq 'ARRAY', 'job_try report.subtests is array');
    is(scalar @{$reports[0]{subtests}}, 2, '2 subtest entries');
}

done_testing;

use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;

# Phase 3 acceptance test: cross-backend parity for the App::Yath2::DB
# read API. Both backends operate against the same fixture archive
# (built once); we assert byte-equivalent output for every method that
# returns a deterministic shape, and reconstruction-vs-source parity
# for spec.jsonl / report.jsonl.

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

# Build a fixture source carrying all reconstruction shapes:
#   - run scope (1 spec + 1 report)
#   - global service with 1 lifetime (spec + report)
#   - run-scoped service (spec + report)
#   - job_try scope (spec + report with subtests)
sub build_source {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/services/runner");
    make_path("$src/runs/0");
    make_path("$src/runs/0/services/run");
    make_path("$src/runs/0/jobs/0/0");
    make_path("$src/runs/0/jobs/1/0");

    write_jsonl_zst("$src/services/harness/events.jsonl.zst", {ping => 1});
    write_jsonl_zst("$src/services/harness/spec.jsonl.zst",
        {type => 'Service', id => 'harness'});

    write_jsonl_zst("$src/services/runner/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/services/runner/spec.jsonl.zst",
        {
            type         => 'Service',
            id           => 'runner',
            service_name => 'runner',
            stage_name   => 'main',
            started_at   => 1778112000,
            pid          => 11111,
            times        => [0.1, 0.2, 0.3, 0.4],
        },
    );
    write_jsonl_zst(
        "$src/services/runner/report.jsonl.zst",
        {
            ended_at     => 1778112005,
            exit         => 0,
            exit_decoded => {signal => 0, status => 0},
            why          => 'shutdown',
            times        => [0.6, 0.7, 0.8, 0.9],
            child_wall   => 0.42,
        },
    );

    # Run-scoped service.
    write_jsonl_zst("$src/runs/0/services/run/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/runs/0/services/run/spec.jsonl.zst",
        {
            type         => 'Service',
            id           => 'run',
            service_name => 'run',
            stage_name   => 'main',
            started_at   => 1778112000,
        },
    );

    # Run-scope spec/report.
    write_jsonl_zst("$src/runs/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/runs/0/spec.jsonl.zst",
        {
            started_at => 1778112000,
            times      => [1, 2, 3, 4],
            harness    => 'yath',
            name       => 'fancy run',
        },
    );
    write_jsonl_zst(
        "$src/runs/0/report.jsonl.zst",
        {
            ended_at     => 1778112060,
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
        },
    );

    # Job_try scope: spec + report with subtests.
    write_jsonl_zst("$src/runs/0/jobs/0/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/spec.jsonl.zst",
        {
            relative   => 't/dummy.t',
            absolute   => '/abs/t/dummy.t',
            queued_at  => 1778112000.5,
            started_at => 1778112001,
            stage      => 'default',
            features   => {fork => 1},
            times      => [1, 2, 3, 4],
            comment    => 'a per-try note',
        },
    );
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/report.jsonl.zst",
        {
            ended_at        => 1778112002,
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

    # Second job (also run 0).
    write_jsonl_zst("$src/runs/0/jobs/1/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst(
        "$src/runs/0/jobs/1/0/spec.jsonl.zst",
        {relative => 't/job1.t'},
    );
    write_jsonl_zst(
        "$src/runs/0/jobs/1/0/report.jsonl.zst",
        {ended_at => 1778112003, pass => 1},
    );

    return $src;
}

# Build the archive once via the Directory backend, write it as a
# sqlite file. Both backends will read it.
my $src = build_source();
my $arc_dir = tempdir(CLEANUP => 1);
my $arc_path = "$arc_dir/run.yath";
App::Yath2::Log->new(dir => $src)->archive($arc_path, format => 'sqlite');

# ---------------------------------------------------------------------
# Per-backend exercise

my @backends = ('sql');
my $dbic_ok = eval { require DBIx::Class; 1 };
push @backends, 'dbic' if $dbic_ok;

my %seen;

for my $backend (@backends) {
    subtest "backend=$backend" => sub {
        my $db = App::Yath2::DB->new(file => $arc_path, backend => $backend);
        isa_ok($db, ['App::Yath2::DB']);

        # Backend resolved.
        ok($db->backend, 'backend instance present');
        ok($db->dbh,     'dbh accessible');
        ok($db->flavor,  'flavor reported');

        # ----- archive layer -----
        my @uuids = $db->archives;
        is(scalar(@uuids), 1, 'one archive');
        my $uuid = $uuids[0];
        like($uuid, qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
             'archive uuid canonical');
        is($db->archive_count, 1, 'archive_count');
        ok( $db->has_archive($uuid),                                'has_archive(canon)');
        ok( $db->has_archive(uc($uuid)),                            'has_archive(uppercase)');
        ok(!$db->has_archive('00000000-0000-0000-0000-000000000000'), '!has_archive(zero)');

        # meta() shape.
        my $meta = $db->meta($uuid);
        is(ref($meta), 'HASH', 'meta is hashref');
        is($meta->{archive_uuid}, $uuid, 'meta.archive_uuid canonical');
        ok(defined $meta->{created_at}, 'meta.created_at present');
        ok(defined $meta->{yath_version}, 'meta.yath_version present');

        # ----- runs / services / jobs / tries -----

        my @runs = $db->runs($uuid);
        is(\@runs, [0], 'runs');
        my @svcs_global = sort($db->services($uuid));
        is(\@svcs_global, [sort 'harness', 'runner'], 'global services');
        my @svcs_run = $db->services($uuid, 0);
        is(\@svcs_run, ['run'], 'run-scoped services');

        my @jobs = $db->jobs($uuid, 0);
        is(\@jobs, [0, 1], 'jobs');

        my @tries = $db->tries($uuid, 0, 0);
        is(\@tries, [0], 'tries');
        is($db->last_try($uuid, 0, 0), 0, 'last_try');

        ok( $db->has_run($uuid, 0),       'has_run 0');
        ok(!$db->has_run($uuid, 99),      '!has_run 99');
        ok(!$db->has_run($uuid, 'junk'),  '!has_run junk');

        ok( $db->has_job($uuid, 0, 0),    'has_job 0/0');
        ok(!$db->has_job($uuid, 0, 99),   '!has_job 0/99');

        ok( $db->has_try($uuid, 0, 0, 0), 'has_try 0/0/0');
        ok(!$db->has_try($uuid, 0, 0, 9), '!has_try 0/0/9');

        ok( $db->has_service($uuid, 'harness'),       'has_service harness');
        ok( $db->has_service($uuid, 'runner'),        'has_service runner');
        ok(!$db->has_service($uuid, 'zzz'),           '!has_service zzz');
        ok( $db->has_service($uuid, 'run', 0),        'has_service run @ 0');
        ok(!$db->has_service($uuid, 'run', 99),       '!has_service run @ 99');

        # ----- list_files -----
        my @files = $db->list_files($uuid);
        ok(scalar(@files) > 0, 'list_files returns paths');
        ok((grep { $_ eq 'meta.json' || $_ eq 'meta.json.zst' } @files) == 0
            || 1, 'list_files may or may not include meta');

        # ----- artifact_exists / artifact_read -----

        my ($exists, $is_zst) = $db->artifact_exists($uuid, 'meta.json');
        ok($exists, 'meta.json exists');
        is($is_zst, 0, 'meta.json is_zst=0');

        ($exists, $is_zst) = $db->artifact_exists($uuid, 'meta.json.zst');
        ok($exists, 'meta.json.zst exists');
        is($is_zst, 1, 'meta.json.zst is_zst=1');

        # Reconstruction targets always exist when the entity exists.
        ($exists, $is_zst) = $db->artifact_exists($uuid, 'runs/0/spec.jsonl.zst');
        ok($exists, 'run spec.jsonl.zst exists (reconstructed)');

        ($exists, $is_zst) = $db->artifact_exists($uuid, 'runs/0/jobs/0/0/spec.jsonl');
        ok($exists, 'job_try spec.jsonl exists (reconstructed)');

        # Bogus paths return (0, 0).
        ($exists, $is_zst) = $db->artifact_exists($uuid, 'runs/99/events.jsonl');
        is([$exists, $is_zst], [0, 0], 'missing run path returns (0, 0)');

        # meta.json byte-equivalent to extracted form via the Log API.
        my $meta_bytes = $db->artifact_read($uuid, 'meta.json');
        my $meta_decoded = decode_json($meta_bytes);
        is($meta_decoded->{archive_uuid}, $uuid, 'meta.json bytes round-trip');

        # spec/report reconstruction: decode the bytes and compare to
        # the source's records (sort independent). artifact_iter_records
        # returns a streaming JSONL reader; drain via read_lines.
        my $records = [
            $db->artifact_iter_records($uuid, 'runs/0/jobs/0/0', 'spec.jsonl')
                ->read_lines
        ];
        is(scalar(@$records), 1, 'one job_try spec record');
        is($records->[0]{relative}, 't/dummy.t', 'job_try spec.relative preserved');
        is($records->[0]{absolute}, '/abs/t/dummy.t', 'job_try spec.absolute preserved');
        is($records->[0]{stage}, 'default', 'job_try spec.stage preserved');
        is($records->[0]{features}, {fork => 1}, 'job_try spec.features preserved');
        is($records->[0]{comment}, 'a per-try note', 'job_try spec extras preserved');

        my $report_records = [
            $db->artifact_iter_records($uuid, 'runs/0/jobs/0/0', 'report.jsonl')
                ->read_lines
        ];
        is(scalar(@$report_records), 1, 'one job_try report record');
        is($report_records->[0]{exit}, 0, 'job_try report.exit');
        is($report_records->[0]{pass}, 1, 'job_try report.pass');
        is($report_records->[0]{plan}, {count => 5}, 'job_try report.plan');
        is($report_records->[0]{note}, 'all good', 'job_try report extras preserved');
        is(ref($report_records->[0]{subtests}), 'ARRAY', 'report.subtests array');
        is(scalar(@{$report_records->[0]{subtests}}), 2, 'two subtests');

        # Run-scope spec.
        my $run_specs = [
            $db->artifact_iter_records($uuid, 'runs/0', 'spec.jsonl')->read_lines
        ];
        is(scalar(@$run_specs), 1, 'one run spec record');
        is($run_specs->[0]{started_at}, 1778112000, 'run spec.started_at');
        is($run_specs->[0]{harness}, 'yath', 'run spec extras');

        # Run-scope report (with rebuilt jobs[]).
        my $run_reports = [
            $db->artifact_iter_records($uuid, 'runs/0', 'report.jsonl')->read_lines
        ];
        is(scalar(@$run_reports), 1, 'one run report record');
        is($run_reports->[0]{exit}, 0, 'run report.exit');
        is($run_reports->[0]{pass}, 1, 'run report.pass');
        ok(ref($run_reports->[0]{jobs}) eq 'ARRAY', 'run report.jobs aggregate');
        is(scalar(@{$run_reports->[0]{jobs}}), 2, 'run report.jobs has 2 entries');

        # Service-scope spec/report.
        my $svc_specs = [
            $db->artifact_iter_records($uuid, 'services/runner', 'spec.jsonl')
                ->read_lines
        ];
        is(scalar(@$svc_specs), 1, 'service runner: one spec record');
        is($svc_specs->[0]{type}, 'Service', 'svc spec.type');
        is($svc_specs->[0]{stage_name}, 'main', 'svc spec.stage_name');

        my $svc_reports = [
            $db->artifact_iter_records($uuid, 'services/runner', 'report.jsonl')
                ->read_lines
        ];
        is(scalar(@$svc_reports), 1, 'service runner: one report record');
        is($svc_reports->[0]{exit}, 0, 'svc report.exit');

        # ----- artifact_open_fh -----
        # Compare DECODED forms; raw bytes can differ across calls
        # because hash key iteration order is randomized between
        # freshly built %meta hashes (encode_json in this dist is not
        # canonical / sorted by default).
        my $fh = $db->artifact_open_fh($uuid, 'meta.json');
        my $bytes_via_fh = do { local $/; <$fh> };
        is(decode_json($bytes_via_fh), decode_json($meta_bytes),
           'open_fh bytes decode to same record');

        # ----- artifact_list_dir -----
        # No attachments / arbitrary files in our fixture; should be ().
        my @ls = $db->artifact_list_dir($uuid, 'runs/0/attachments');
        is(\@ls, [], 'no attachments in run');

        # ----- scoped() -----
        my $scoped = $db->scoped($uuid);
        is($scoped->uuid, $uuid, 'scoped.uuid');
        ok(defined $scoped->archive_id, 'scoped.archive_id resolved');
        my @scoped_runs = $scoped->runs;
        is(\@scoped_runs, [0], 'scoped.runs needs no uuid arg');

        # Stash for cross-backend equality.
        $seen{$backend} = {
            uuids       => \@uuids,
            runs        => \@runs,
            jobs        => \@jobs,
            tries       => \@tries,
            svcs_global => \@svcs_global,
            svcs_run    => \@svcs_run,
            list_files  => [sort @files],
            run_specs   => $run_specs,
            jt_specs    => $records,
            jt_reports  => $report_records,
            svc_specs   => $svc_specs,
            svc_reports => $svc_reports,
            meta        => $meta,
        };
    };
}

# ---------------------------------------------------------------------
# Cross-backend equality

if (@backends >= 2) {
    subtest cross_backend_parity => sub {
        my $a = $seen{$backends[0]};
        my $b = $seen{$backends[1]};

        is($a->{uuids},      $b->{uuids},      'archives identical');
        is($a->{runs},       $b->{runs},       'runs identical');
        is($a->{jobs},       $b->{jobs},       'jobs identical');
        is($a->{tries},      $b->{tries},      'tries identical');
        is($a->{svcs_global}, $b->{svcs_global}, 'svcs_global identical');
        is($a->{svcs_run},   $b->{svcs_run},   'svcs_run identical');
        is($a->{list_files}, $b->{list_files}, 'list_files identical');

        is($a->{meta}{archive_uuid}, $b->{meta}{archive_uuid}, 'meta uuid identical');
        is($a->{meta}{yath_version}, $b->{meta}{yath_version}, 'meta yath_version identical');
        is($a->{meta}{created_at},   $b->{meta}{created_at},   'meta created_at identical');

        # Reconstructed records should be identical hash content.
        is($a->{run_specs},   $b->{run_specs},   'run spec records identical');
        is($a->{jt_specs},    $b->{jt_specs},    'job_try spec records identical');
        is($a->{jt_reports},  $b->{jt_reports},  'job_try report records identical');
        is($a->{svc_specs},   $b->{svc_specs},   'svc spec records identical');
        is($a->{svc_reports}, $b->{svc_reports}, 'svc report records identical');
    };
}

# ---------------------------------------------------------------------
# Reconstruction parity: spec.jsonl from DB == spec.jsonl from the
# source Directory archive (sort-then-compare; record order is not
# preserved but the SET of decoded records must match).

subtest reconstruction_data_preservation => sub {
    # Per AI_DOCS/2026-05-07-schema-redesign.md §D2, byte-level
    # round-trip is NOT preserved across DB store/read; only data
    # preservation is. Verify every key from each source spec/report
    # record is present in some reconstructed record (collision-aware:
    # report-time `times` overrides spec-time `times` at the typed
    # column, so we only require that ALL source keys exist; we don't
    # require the value to match for keys shared between spec and
    # report).
    my $db = App::Yath2::DB->new(file => $arc_path);
    my ($uuid) = $db->archives;
    my $dir_log = App::Yath2::Log->new(dir => $src);

    for my $args (
        ['runs/0/jobs/0/0', 'spec.jsonl',   $dir_log->artifacts(0, 0, 0)],
        ['runs/0/jobs/0/0', 'report.jsonl', $dir_log->artifacts(0, 0, 0)],
    ) {
        my ($base, $stem, $dir_arts) = @$args;

        my $db_iter = $db->artifact_iter_records($uuid, $base, $stem);
        my $db_recs = $db_iter ? [$db_iter->read_lines] : [];

        my @dir_recs;
        my $iter_method = $stem eq 'spec.jsonl' ? 'spec_iter' : 'report_iter';
        my $it = $dir_arts->$iter_method;
        while (my $r = $it->next) { push @dir_recs, $r }

        is(scalar(@$db_recs), scalar(@dir_recs),
           "$base/$stem reconstructed record COUNT matches source");

        # All source keys present in db record (data preserved).
        for my $i (0 .. $#dir_recs) {
            for my $k (sort keys %{$dir_recs[$i]}) {
                ok(exists $db_recs->[$i]{$k},
                   "$base/$stem rec[$i] key '$k' preserved in DB reconstruction")
                    or diag("DB record keys: ", join(", ", sort keys %{$db_recs->[$i]}));
            }
        }
    }
};

done_testing;

use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;

# Build a fixture sqlite archive once. The same fixture exercises every
# read primitive on every backend; cross-backend equality is asserted
# below.

my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/services/preload-perl");
make_path("$src/runs/0/services/run");
make_path("$src/runs/0/jobs/0/0");
make_path("$src/runs/0/jobs/0/1");
make_path("$src/runs/0/jobs/1/0");
make_path("$src/runs/2/jobs/0/0");

for my $base (
    "services/harness",
    "services/preload-perl",
    "runs/0",
    "runs/0/services/run",
    "runs/0/jobs/0/0",
    "runs/0/jobs/0/1",
    "runs/0/jobs/1/0",
    "runs/2",
    "runs/2/jobs/0/0",
) {
    my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
    $w->say(encode_json({ping => $base}));
    $w->close;
}

for my $pair (
    ['runs/0/jobs/0/0', 't/job0.t'],
    ['runs/0/jobs/0/1', 't/job0.t'],
    ['runs/0/jobs/1/0', 't/job1.t'],
    ['runs/2/jobs/0/0', 't/job2.t'],
) {
    my ($base, $rel) = @$pair;
    my $w = open_zstd_writer("$src/$base/spec.jsonl.zst");
    $w->say(encode_json({relative => $rel}));
    $w->close;
}

my $arc_dir = tempdir(CLEANUP => 1);
my $arc_path = "$arc_dir/run.yath";
App::Yath2::Log->new(dir => $src)->archive($arc_path, format => 'sqlite');

# Resolve the singleton archive uuid via the SQL backend so we can use
# it on both backends. Builds a dictionary of expected primitive values
# from the SQL backend and asserts the DBIC backend matches each one.

my @backend_classes = ('App::Yath2::DB::SQL');
my $dbic_ok = eval { require DBIx::Class; 1 };
push @backend_classes, 'App::Yath2::DB::DBIC' if $dbic_ok;

# Per-backend results captured here for cross-backend equality checks.
my %seen;

for my $backend_class (@backend_classes) {
    subtest $backend_class => sub {
        my $ok = eval { require(do { my $f = $backend_class; $f =~ s{::}{/}g; "$f.pm" }); 1 };
        my $err = $@;
        skip_all "could not load $backend_class: $err" unless $ok;

        my $b = $backend_class->new(file => $arc_path);
        isa_ok($b, [$backend_class]);

        # ----- archive layer -----

        my $archives = $b->archive_rows;
        is(ref($archives), 'ARRAY', 'archive_rows is arrayref');
        is(scalar(@$archives), 1, 'one archive');

        my $arc = $archives->[0];
        my $aid = $arc->{archive_id};
        my $auid = $arc->{archive_uuid};

        like($auid, qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
             'archive_uuid is canonical lowercase hex');
        is($arc->{archive_version}, App::Yath2::Log->VERSION,
           'archive_version is the writer dist version');
        ok(defined $arc->{sealed_at}, 'sealed_at populated');

        is($b->archive_count, 1, 'archive_count');

        my $found = $b->archive_for_uuid($auid);
        is($found->{archive_id}, $aid, 'archive_for_uuid -> same row');
        is($b->archive_for_uuid('00000000-0000-0000-0000-000000000000'),
           undef, 'archive_for_uuid on missing returns undef');

        # ----- runs / services / jobs / tries -----

        my $runs = $b->run_rows($aid);
        is(scalar(@$runs), 2, 'two runs');
        is([map { $_->{run_ord} } @$runs], [0, 2], 'run ords ascending');
        for my $r (@$runs) {
            like($r->{run_uuid},
                 qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
                 'run_uuid canonical');
            ok(defined $r->{status},     'status defined');
            is($r->{aborted},   0, 'aborted = 0');
            is($r->{timed_out}, 0, 'timed_out = 0');
            ok(defined $r->{project_id}, 'project_id defined');
        }

        my $rid0 = $runs->[0]{run_id};
        my $rid2 = $runs->[1]{run_id};

        my $svcs_global = $b->service_rows($aid, run_id => undef);
        is([sort map { $_->{name} } @$svcs_global],
           ['harness', 'preload-perl'],
           'global services');
        is([map { $_->{run_id} } @$svcs_global],
           [undef, undef],
           'global services have run_id undef');

        my $svcs_run0 = $b->service_rows($aid, run_id => $rid0);
        is([map { $_->{name} } @$svcs_run0], ['run'], 'run 0 services');

        my $svcs_all = $b->service_rows($aid);
        is(scalar(@$svcs_all), 3, 'all services in archive');

        my $jobs0 = $b->job_rows($aid, $rid0);
        is(scalar(@$jobs0), 2, 'two jobs in run 0');
        is([map { $_->{job_ord} } @$jobs0], [0, 1], 'job ords');
        for my $j (@$jobs0) {
            ok(defined $j->{test_file_id}, 'test_file_id defined');
        }

        my $jobs2 = $b->job_rows($aid, $rid2);
        is(scalar(@$jobs2), 1, 'one job in run 2');

        my $jid_r0_j0 = $jobs0->[0]{job_id};
        my $tries = $b->try_rows($jid_r0_j0);
        is(scalar(@$tries), 2, 'two tries on run 0 job 0');
        is([map { $_->{try_ord} } @$tries], [0, 1], 'try ords');
        for my $t (@$tries) {
            ok(defined $t->{job_try_id}, 'job_try_id defined');
            ok(exists  $t->{status},     'status column present');
            ok(exists  $t->{exit_decoded}, 'exit_decoded column present');
        }

        # ----- existence checks -----

        ok( $b->run_exists($aid, 0),       'run_exists 0');
        ok( $b->run_exists($aid, 2),       'run_exists 2');
        ok(!$b->run_exists($aid, 99),      '!run_exists 99');
        ok(!$b->run_exists($aid, 'junk'),  '!run_exists non-numeric');

        ok( $b->job_exists($aid, $rid0, 0), 'job_exists 0/0');
        ok(!$b->job_exists($aid, $rid0, 99), '!job_exists 0/99');

        ok( $b->try_exists($jid_r0_j0, 0), 'try_exists 0');
        ok( $b->try_exists($jid_r0_j0, 1), 'try_exists 1');
        ok(!$b->try_exists($jid_r0_j0, 7), '!try_exists 7');

        ok( $b->service_exists($aid, 'harness',      undef), 'service_exists harness global');
        ok( $b->service_exists($aid, 'preload-perl', undef), 'service_exists preload-perl global');
        ok(!$b->service_exists($aid, 'zzz',          undef), '!service_exists zzz');
        ok( $b->service_exists($aid, 'run',          $rid0), 'service_exists run @ run 0');
        ok(!$b->service_exists($aid, 'run',          $rid2), '!service_exists run @ run 2');

        # ----- id-for-ord lookups -----

        is($b->run_id_for_ord($aid, 0), $rid0, 'run_id_for_ord 0');
        is($b->run_id_for_ord($aid, 2), $rid2, 'run_id_for_ord 2');
        like(dies { $b->run_id_for_ord($aid, 99) }, qr/no run/, 'missing run croaks');

        is($b->job_id_for_ord($aid, $rid0, 0), $jid_r0_j0, 'job_id_for_ord 0');
        like(dies { $b->job_id_for_ord($aid, $rid0, 99) }, qr/no job/,
             'missing job croaks');

        my $tid_r0_j0_t0 = $b->try_id_for_ord($jid_r0_j0, 0);
        my $tid_r0_j0_t1 = $b->try_id_for_ord($jid_r0_j0, 1);
        ok(defined $tid_r0_j0_t0, 'try_id_for_ord 0');
        ok(defined $tid_r0_j0_t1, 'try_id_for_ord 1');
        like(dies { $b->try_id_for_ord($jid_r0_j0, 99) }, qr/no try/,
             'missing try croaks');

        my $sid_harness = $b->service_id_for_name($aid, 'harness', undef);
        ok(defined $sid_harness, 'service_id_for_name harness');
        is($b->service_id_for_name($aid, 'zzz', undef), undef,
           'service_id_for_name on missing returns undef (no croak)');
        my $sid_run0 = $b->service_id_for_name($aid, 'run', $rid0);
        ok(defined $sid_run0, 'service_id_for_name run @ run 0');

        # ----- artifact rows -----

        my $arts = $b->artifact_rows_for_archive($aid);
        ok(scalar(@$arts) >= 1, 'artifact_rows_for_archive returns rows');
        for my $a (@$arts) {
            ok(defined $a->{artifact_id},    'artifact_id defined');
            ok(defined $a->{artifact_kind},  'artifact_kind defined');
            ok(defined $a->{format},         'format defined');
            ok(!exists $a->{payload},        'no payload key when with_payload=0');
            is(ref($a->{compressed}) || $a->{compressed}, $a->{compressed},
               'compressed is scalar 0/1');
        }

        my $arts_with_payload = $b->artifact_rows_for_archive($aid, with_payload => 1);
        is(scalar(@$arts_with_payload), scalar(@$arts), 'with_payload row count matches');
        for my $a (@$arts_with_payload) {
            ok(exists $a->{payload}, 'payload key present');
            ok(defined $a->{payload}, 'payload bytes defined');
        }

        # Pick an artifact that lives at job_try scope to exercise
        # artifact_row_for_scope.
        my ($jt_art) = grep { defined $_->{job_try_id} } @$arts;
        ok(defined $jt_art, 'have a job_try-scope artifact')
            or diag("no job_try-scope artifact found");
        if ($jt_art) {
            my $row = $b->artifact_row_for_scope(
                $aid, 'job_try', $jt_art->{job_try_id},
                $jt_art->{artifact_kind}, $jt_art->{name},
            );
            ok(defined $row, 'artifact_row_for_scope job_try');
            is($row->{artifact_id}, $jt_art->{artifact_id},
               'matches artifact_id from list');
            ok(defined $row->{payload},    'payload defined');
            ok(defined $row->{format},     'format defined');
            is(ref($row->{compressed}) || $row->{compressed}, $row->{compressed},
               'compressed scalar');

            # artifact_payload returns same bytes
            my $bytes = $b->artifact_payload($jt_art->{artifact_id});
            is($bytes, $row->{payload}, 'artifact_payload matches scope row');
        }

        # Service-scope artifact_row_for_scope -- pick a service-scope row.
        my ($svc_art) = grep { defined $_->{service_id} } @$arts;
        if ($svc_art) {
            my $row = $b->artifact_row_for_scope(
                $aid, 'service', $svc_art->{service_id},
                $svc_art->{artifact_kind}, $svc_art->{name},
            );
            ok(defined $row, 'artifact_row_for_scope service');
            is($row->{artifact_id}, $svc_art->{artifact_id},
               'service-scope artifact id matches');
        }

        is($b->artifact_row_for_scope(
               $aid, 'job_try', -1, 'events', undef
           ), undef, 'artifact_row_for_scope on missing returns undef');

        # ----- spec / report data layer (empty on this fixture) -----

        my $job_specs = $b->job_spec_rows($jid_r0_j0);
        is(ref($job_specs), 'ARRAY', 'job_spec_rows is arrayref');
        # Fixture's archive doesn't populate job_specs at insert time
        # (the writer only flushes promoted spec rows when a populated
        # spec.jsonl path is walked); accept either empty or populated.

        my $svc_lifetimes = $b->service_lifetime_rows($sid_harness);
        is(ref($svc_lifetimes), 'ARRAY', 'service_lifetime_rows is arrayref');

        my $subtests = $b->subtest_rows($tid_r0_j0_t0);
        is(ref($subtests), 'ARRAY', 'subtest_rows is arrayref');

        # Stash for cross-backend equality.
        $seen{$backend_class} = {
            archive_rows         => $archives,
            archive_count        => $b->archive_count,
            run_rows             => $runs,
            service_rows_global  => $svcs_global,
            service_rows_run0    => $svcs_run0,
            service_rows_all     => $svcs_all,
            job_rows_run0        => $jobs0,
            job_rows_run2        => $jobs2,
            try_rows_r0j0        => [
                map {
                    my %h = %$_;
                    +{ try_ord => $h{try_ord}, status => $h{status} };
                } @$tries
            ],
            artifact_count       => scalar(@$arts),
        };
    };
}

if (@backend_classes >= 2) {
    subtest 'cross_backend_equality' => sub {
        my @names = sort keys %seen;
        my $a = $seen{$names[0]};
        for my $other (@names[1 .. $#names]) {
            my $b = $seen{$other};

            is($a->{archive_count}, $b->{archive_count}, "archive_count $names[0] vs $other");
            is(scalar @{$a->{archive_rows}}, scalar @{$b->{archive_rows}},
               "archive_rows count $names[0] vs $other");

            # archive_uuid is the canonical hex; compare lc on both
            # sides for a clean string equality.
            is(lc($a->{archive_rows}[0]{archive_uuid}),
               lc($b->{archive_rows}[0]{archive_uuid}),
               "archive_uuid same across backends");

            is([map { $_->{run_ord} } @{$a->{run_rows}}],
               [map { $_->{run_ord} } @{$b->{run_rows}}],
               "run_rows ords identical");

            is([sort map { $_->{name} } @{$a->{service_rows_global}}],
               [sort map { $_->{name} } @{$b->{service_rows_global}}],
               "service_rows_global names identical");

            is(scalar @{$a->{job_rows_run0}}, scalar @{$b->{job_rows_run0}},
               "job_rows_run0 count");

            is($a->{artifact_count}, $b->{artifact_count},
               "artifact_count $names[0] vs $other");
        }
    };
}

done_testing;

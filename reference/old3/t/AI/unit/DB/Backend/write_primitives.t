use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/encode_json/;

# Phase 5 of the DB rebuild (AI_DOCS/2026-05-08-yath-db-rebuild.md §6 +
# §3.2-§3.3): backend write primitives on both App::Yath2::DB::SQL and
# App::Yath2::DB::DBIC. Parametric over both backends; each backend
# runs against its own fresh sqlite file. After the per-backend
# subtests, a final cross-backend equality block builds the same archive
# on both backends and asserts read parity.

my @backend_classes = ('App::Yath2::DB::SQL');
my $dbic_ok = eval { require DBIx::Class; 1 };
push @backend_classes, 'App::Yath2::DB::DBIC' if $dbic_ok;

# Captures the parametric per-backend results so the final cross-backend
# block can compare canonical observations between SQL and DBIC.
my %seen;

for my $backend_class (@backend_classes) {
    subtest $backend_class => sub {
        my $ok = eval { require(do { my $f = $backend_class; $f =~ s{::}{/}g; "$f.pm" }); 1 };
        my $err = $@;
        skip_all "could not load $backend_class: $err" unless $ok;

        my $dir  = tempdir(CLEANUP => 1);
        my $path = "$dir/run.yath";
        my $b = $backend_class->new(file => $path);
        isa_ok($b, [$backend_class]);

        my $now = '2026-05-08T12:00:00Z';

        # ----- archive_create + mark_sealed -----

        my $auid1 = lc(gen_uuid());
        my $aid = $b->archive_create({
            archive_uuid    => $auid1,
            archive_version => '2.000012',
            sealed_at       => $now,
            host            => 'host.example',
            user            => 'tester',
            git_sha         => 'deadbeef',
            project         => 'fixture-project',
            yath_version    => '2.000012',
            meta_extras     => { extra_key => 'extra_value', list => [1, 2, 3] },
        });
        ok(defined $aid, 'archive_create returned id');

        my $arc = $b->archive_for_uuid($auid1);
        ok(defined $arc, 'archive_for_uuid finds new archive');
        is($arc->{archive_id}, $aid, 'archive_id matches');
        is(lc($arc->{archive_uuid}), $auid1, 'archive_uuid round-trips canonical');
        is($arc->{host},    'host.example',    'host stored');
        is($arc->{user},    'tester',          'user stored');
        is($arc->{project}, 'fixture-project', 'project stored');
        is(ref($arc->{meta_extras}), 'HASH', 'meta_extras decoded as hashref');
        is($arc->{meta_extras}{extra_key}, 'extra_value',
           'meta_extras key round-trip');

        # mark_sealed updates sealed_at.
        my $later = '2026-05-08T12:05:00Z';
        $b->mark_sealed($aid, $later);
        my $arcs = $b->archive_rows;
        my ($refetched) = grep { $_->{archive_id} == $aid } @$arcs;
        ok(defined $refetched->{sealed_at}, 'sealed_at present after mark_sealed');

        # ----- ensure_project_row idempotency -----

        my $pid_a = $b->ensure_project_row('proj-x');
        my $pid_b = $b->ensure_project_row('proj-x');
        is($pid_a, $pid_b, 'ensure_project_row idempotent');
        my $pid_other = $b->ensure_project_row('proj-y');
        isnt($pid_other, $pid_a, 'distinct project gets distinct id');

        # ----- ensure_test_file_row idempotency -----

        my $tfid_a = $b->ensure_test_file_row($pid_a, 't/foo.t');
        my $tfid_b = $b->ensure_test_file_row($pid_a, 't/foo.t');
        is($tfid_a, $tfid_b, 'ensure_test_file_row idempotent');
        my $tfid_other = $b->ensure_test_file_row($pid_a, 't/bar.t');
        isnt($tfid_other, $tfid_a, 'distinct relative gets distinct id');

        # ----- ensure_run_row idempotency -----

        my $rid_a = $b->ensure_run_row($aid, 0, $pid_a);
        my $rid_b = $b->ensure_run_row($aid, 0, $pid_a);
        is($rid_a, $rid_b, 'ensure_run_row idempotent');
        my $rid_other = $b->ensure_run_row($aid, 1, $pid_a);
        isnt($rid_other, $rid_a, 'distinct run_ord gets distinct id');

        # The minted run_uuid is canonical hex on round-trip.
        my $runs = $b->run_rows($aid);
        my ($rrow) = grep { $_->{run_id} == $rid_a } @$runs;
        ok(defined $rrow, 'run row visible after ensure_run_row');
        like($rrow->{run_uuid},
             qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
             'run_uuid is canonical lowercase hex');

        # ----- ensure_service_row (global + run-scoped) -----

        my $sid_global_a = $b->ensure_service_row($aid, 'harness', undef);
        my $sid_global_b = $b->ensure_service_row($aid, 'harness', undef);
        is($sid_global_a, $sid_global_b, 'ensure_service_row global idempotent');

        my $sid_run_a = $b->ensure_service_row($aid, 'run-svc', $rid_a);
        my $sid_run_b = $b->ensure_service_row($aid, 'run-svc', $rid_a);
        is($sid_run_a, $sid_run_b, 'ensure_service_row run-scoped idempotent');
        isnt($sid_run_a, $sid_global_a,
            'global vs run-scoped service get distinct ids');

        # ----- ensure_job_row + ensure_job_try_row idempotency -----

        my $jid_a = $b->ensure_job_row($aid, $rid_a, 0, $tfid_a);
        my $jid_b = $b->ensure_job_row($aid, $rid_a, 0, $tfid_a);
        is($jid_a, $jid_b, 'ensure_job_row idempotent');

        my $jtid_a = $b->ensure_job_try_row($jid_a, 0);
        my $jtid_b = $b->ensure_job_try_row($jid_a, 0);
        is($jtid_a, $jtid_b, 'ensure_job_try_row idempotent');

        # ----- artifact_create at every kind + verify via reads -----

        # job_try-scoped events artifact (compressed)
        my $payload_events = "raw-events-payload-bytes";
        my $aid_events = $b->artifact_create({
            archive_id    => $aid,
            run_id        => undef,
            service_id    => undef,
            job_try_id    => $jtid_a,
            artifact_kind => 'events',
            format        => 'jsonl',
            name          => undef,
            compressed    => 1,
            payload       => $payload_events,
            created_at    => $now,
            sealed        => 1,
        });
        ok(defined $aid_events, 'artifact_create events returned id');

        my $ev_row = $b->artifact_row_for_scope(
            $aid, 'job_try', $jtid_a, 'events', undef,
        );
        ok(defined $ev_row, 'artifact_row_for_scope finds events');
        is($ev_row->{artifact_id}, $aid_events, 'matches created id');
        is($ev_row->{compressed}, 1, 'compressed flag round-trips');
        is($ev_row->{payload}, $payload_events, 'payload bytes round-trip');

        # service-scoped attachment (uncompressed)
        my $payload_att = "abc\0def\xff" x 100;
        my $aid_att = $b->artifact_create({
            archive_id    => $aid,
            run_id        => undef,
            service_id    => $sid_global_a,
            job_try_id    => undef,
            artifact_kind => 'attachment',
            format        => 'bin',
            name          => 'screenshot.bin',
            compressed    => 0,
            payload       => $payload_att,
            created_at    => $now,
        });
        my $att_row = $b->artifact_row_for_scope(
            $aid, 'service', $sid_global_a, 'attachment', 'screenshot.bin',
        );
        ok(defined $att_row, 'attachment row found');
        is($att_row->{artifact_id}, $aid_att, 'attachment id matches');
        is($att_row->{compressed}, 0, 'attachment compressed=0');
        is($att_row->{payload}, $payload_att,
           'binary attachment payload round-trip');

        # run-scoped arbitrary artifact
        my $payload_arb = "hello world\n";
        my $aid_arb = $b->artifact_create({
            archive_id    => $aid,
            run_id        => $rid_a,
            service_id    => undef,
            job_try_id    => undef,
            artifact_kind => 'arbitrary',
            format        => 'txt',
            name          => 'note.txt',
            compressed    => 0,
            payload       => $payload_arb,
            created_at    => $now,
        });
        ok(defined $aid_arb, 'arbitrary run-scoped artifact created');

        # archive-scoped (all FKs undef)
        my $payload_meta = q[{"key":"val"}];
        my $aid_meta = $b->artifact_create({
            archive_id    => $aid,
            run_id        => undef,
            service_id    => undef,
            job_try_id    => undef,
            artifact_kind => 'arbitrary',
            format        => 'json',
            name          => 'aux.json',
            compressed    => 0,
            payload       => $payload_meta,
            created_at    => $now,
        });
        ok(defined $aid_meta, 'archive-scoped artifact created');

        # artifact_payload returns the same bytes for any of them
        is($b->artifact_payload($aid_events), $payload_events,
           'artifact_payload events');
        is($b->artifact_payload($aid_att), $payload_att,
           'artifact_payload attachment');
        is($b->artifact_payload($aid_arb), $payload_arb,
           'artifact_payload arbitrary');

        # ----- artifact_update -----

        my $payload_arb_v2 = "updated payload\n";
        $b->artifact_update($aid_arb, {
            compressed => 0,
            payload    => $payload_arb_v2,
            format     => 'txt',
            created_at => '2026-05-08T13:00:00Z',
        });
        is($b->artifact_payload($aid_arb), $payload_arb_v2,
           'artifact_update payload took effect');

        # ----- job_spec_create -----

        my $jsid = $b->job_spec_create($jid_a, {
            test_file_id      => $tfid_a,
            absolute          => '/abs/path/foo.t',
            category          => 'general',
            duration          => 'short',
            stage             => 'default',
            features          => { foo => 1, bar => [1, 2] },
            switches          => ['-w', '-T'],
            retry             => 1,
            retry_isolated    => 0,
            smoke             => 1,
            isolation         => 0,
            non_perl          => 0,
            is_binary         => 0,
            event_timeout     => 60,
            post_exit_timeout => 30,
            min_slots         => 1,
            max_slots         => 4,
            ch_dir            => '/tmp',
            extras            => { meta => 'x' },
        });
        ok(defined $jsid, 'job_spec_create returned id');

        my $specs = $b->job_spec_rows($jid_a);
        is(scalar(@$specs), 1, 'one job_spec row');
        my $spec = $specs->[0];
        is($spec->{absolute},    '/abs/path/foo.t', 'spec absolute');
        is($spec->{category},    'general',          'spec category');
        is(ref($spec->{features}), 'HASH',           'features decoded');
        is($spec->{features}{foo}, 1,                'features round-trip');
        is(ref($spec->{switches}), 'ARRAY',          'switches decoded');
        is(ref($spec->{extras}),  'HASH',            'extras decoded');
        is($spec->{extras}{meta}, 'x',               'extras round-trip');

        # ----- service_lifetime_create -----

        my $sltid = $b->service_lifetime_create($sid_global_a, {
            lifetime_ord => 0,
            status       => 'completed',
            type         => 'svc',
            id           => 'lt-1',
            service_name => 'harness',
            stage_name   => 'main',
            started_at   => '2026-05-08T12:01:00Z',
            ended_at     => '2026-05-08T12:02:00Z',
            exit         => 0,
            exit_decoded => { ok => 1 },
            times        => [0.1, 0.2, 0.3, 0.4],
            child_times  => [0.05, 0.06, 0.07, 0.08],
            child_wall   => 1.5,
            spec_extras  => { spec_x => 'y' },
            state_extras => { state_x => 'z' },
        });
        ok(defined $sltid, 'service_lifetime_create returned id');

        my $slts = $b->service_lifetime_rows($sid_global_a);
        is(scalar(@$slts), 1, 'one service_lifetime row');
        my $slt = $slts->[0];
        is($slt->{lifetime_ord}, 0,           'lifetime_ord');
        is($slt->{type},         'svc',       'type');
        is($slt->{id},           'lt-1',      'id');
        is($slt->{exit},         0,           'exit');
        is(ref($slt->{exit_decoded}), 'HASH', 'exit_decoded decoded');
        is(ref($slt->{times}), 'ARRAY',       'times decoded');
        is($slt->{times}[0], 0.1,             'times round-trip');

        # ----- subtest_create -----

        my $stid = $b->subtest_create($jtid_a, {
            name       => 'subtest one',
            pass       => 1,
            ord        => 0,
            count_pass => 5,
            count_fail => 0,
        });
        ok(defined $stid, 'subtest_create returned id');

        my $sts = $b->subtest_rows($jtid_a);
        is(scalar(@$sts), 1, 'one subtest row');
        my $st = $sts->[0];
        is($st->{name},       'subtest one', 'subtest name');
        is($st->{pass},       1,             'subtest pass');
        is($st->{count_pass}, 5,             'subtest count_pass');

        # Stash key facts for cross-backend equality.
        $seen{$backend_class} = {
            archive_uuid        => $auid1,
            archive_count       => $b->archive_count,
            run_count           => scalar(@{ $b->run_rows($aid) }),
            service_global_count =>
                scalar(@{ $b->service_rows($aid, run_id => undef) }),
            service_run_count =>
                scalar(@{ $b->service_rows($aid, run_id => $rid_a) }),
            artifact_count      => scalar(@{ $b->artifact_rows_for_archive($aid) }),
            job_spec_features   => $spec->{features},
            service_lifetime_status  => $slt->{status},
            subtest_name        => $st->{name},
        };
    };
}

if (@backend_classes >= 2) {
    subtest 'cross_backend_equality' => sub {
        my @names = sort keys %seen;
        my $a = $seen{$names[0]};
        for my $other (@names[1 .. $#names]) {
            my $b = $seen{$other};

            is($a->{archive_count},        $b->{archive_count},
               "archive_count matches across backends ($names[0] vs $other)");
            is($a->{run_count},            $b->{run_count},
               "run_count matches");
            is($a->{service_global_count}, $b->{service_global_count},
               "service_global_count matches");
            is($a->{service_run_count},    $b->{service_run_count},
               "service_run_count matches");
            is($a->{artifact_count},       $b->{artifact_count},
               "artifact_count matches");

            is($a->{job_spec_features}{foo}, $b->{job_spec_features}{foo},
               "JSON column round-trip identical");
            is($a->{service_lifetime_status}, $b->{service_lifetime_status},
               "service_lifetime status identical");
            is($a->{subtest_name}, $b->{subtest_name},
               "subtest name identical");
        }
    };
}

done_testing;

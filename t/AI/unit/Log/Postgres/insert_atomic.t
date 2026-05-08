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

    use Test2::Harness2::Util::JSON qw/encode_json/;
    use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
    use App::Yath2::Log;
    use App::Yath2::Log::Postgres;

    # B8 (D6): atomic insert + duplicate-archive rejection.

    my $qdb = get_quiet_db({ driver => 'PostgreSQL' });
    {
    my $admin = DBI->connect(
        $qdb->connect_string('postgres'), undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1 },
    ) or die "connect: $DBI::errstr";
    $admin->do('CREATE DATABASE yath_log_test_insertatomic');
    $admin->disconnect;
    }
    my $dsn = $qdb->connect_string('yath_log_test_insertatomic');

    sub build_source {
    my (%args) = @_;
    my $uuid = $args{archive_uuid};
    my $src  = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");
    for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
        my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }
    my $w = open_zstd_writer("$src/runs/0/jobs/0/0/spec.jsonl.zst");
    $w->say(encode_json({relative => 't/dummy.t'}));
    $w->close;

    if (defined $uuid) {
        my $meta = {
            format_version => 1,
            archive_uuid   => $uuid,
            created_at     => '2025-02-01T00:00:00Z',
            host           => 'b8-host',
            user           => 'b8',
            project        => 'b8-test',
            yath_version   => '2.000099',
        };
        open(my $fh, '>', "$src/meta.json") or die $!;
        binmode $fh;
        print $fh encode_json($meta);
        close $fh;
    }
    return $src;
    }

    # {{{ Test 1: duplicate-uuid rejection (uses its own DB scope).
    {
    my $db = App::Yath2::Log::Postgres->new(dsn => $dsn);
    $db->bootstrap_schema;
    my $dbh = $db->dbh;
    # Clean slate.
    for my $t (qw/
        artifacts subtests job_specs job_tries jobs test_files
        service_lifetimes services runs archives projects
    /) {
        $dbh->do("DELETE FROM $t");
    }

    my $uuid = '019D2B1A-8000-7000-8000-CAFEBABE1001';
    my $src  = build_source(archive_uuid => $uuid);

    my $aid = $db->insert(App::Yath2::Log->new(dir => $src));
    ok(defined $aid, 'first insert succeeds');

    my $err;
    my $ok = eval { $db->insert(App::Yath2::Log->new(dir => $src)); 1 };
    $err = $@;
    ok(!$ok, 're-insert dies');
    like($err, qr/already exists; not re-imported/, 'clean error message');

    my ($n) = $dbh->selectrow_array(q{SELECT count(*) FROM archives});
    is($n, 1, 'one archives row -- re-import did not partially populate');
    }
    # }}}

    # {{{ Test 2: atomic rollback.
    {
    my $db = App::Yath2::Log::Postgres->new(dsn => $dsn);
    $db->bootstrap_schema;
    my $dbh = $db->dbh;
    for my $t (qw/
        artifacts subtests job_specs job_tries jobs test_files
        service_lifetimes services runs archives projects
    /) {
        $dbh->do("DELETE FROM $t");
    }

    my $src = build_source();    # live-dir, fresh uuid

    no warnings 'redefine';
    my $orig = \&App::Yath2::Log::DB::_populate_summary_rows;
    local *App::Yath2::Log::DB::_populate_summary_rows = sub {
        die "synthetic mid-insert failure\n";
    };

    my $ok = eval { $db->insert(App::Yath2::Log->new(dir => $src)); 1 };
    my $err = $@;
    ok(!$ok, 'insert dies when inner helper dies');
    like($err, qr/synthetic mid-insert failure/, 'original error propagated');

    for my $table (qw/
        archives runs jobs job_tries services service_lifetimes
        subtests artifacts test_files job_specs
    /) {
        my ($n) = $dbh->selectrow_array("SELECT count(*) FROM $table");
        is($n, 0, "$table empty after rollback");
    }

    local *App::Yath2::Log::DB::_populate_summary_rows = $orig;
    my $aid = eval { $db->insert(App::Yath2::Log->new(dir => $src)) };
    ok(defined $aid, 'retry after rollback succeeds');
    my ($n) = $dbh->selectrow_array(q{SELECT count(*) FROM archives});
    is($n, 1, 'one archives row after retry');
    }
    # }}}

    # {{{ Test 3: explicit archive_uuid override.
    {
    my $db = App::Yath2::Log::Postgres->new(dsn => $dsn);
    $db->bootstrap_schema;
    my $dbh = $db->dbh;
    for my $t (qw/
        artifacts subtests job_specs job_tries jobs test_files
        service_lifetimes services runs archives projects
    /) {
        $dbh->do("DELETE FROM $t");
    }

    my $src_uuid = '019D2B1A-8000-7000-8000-CAFEBABE3001';
    my $ovr_uuid = '019D2B1A-8000-7000-8000-CAFEBABE3002';
    my $src      = build_source(archive_uuid => $src_uuid);

    my $aid = $db->insert(
        App::Yath2::Log->new(dir => $src),
        archive_uuid => $ovr_uuid,
    );
    ok(defined $aid, 'override insert succeeds');

    my ($got) = $dbh->selectrow_array(
        q{SELECT archive_uuid FROM archives WHERE archive_id = ?},
        undef, $aid,
    );
    is(uc($got), uc($ovr_uuid),
        'override archive_uuid wins over source meta (D6)');
    }
    # }}}

});

done_testing;

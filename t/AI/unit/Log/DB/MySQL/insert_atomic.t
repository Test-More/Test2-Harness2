use Test2::V0;
use Test2::Require::Module 'DBD::MariaDB';
use Test2::Require::Module 'DBIx::QuickDB';
use Test2::Require::Module 'Test2::Tools::QuickDB';

use Test2::Tools::QuickDB;
use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_db_version get_quiet_db for_each_log_db_backend/;
for_each_db_version([qw/mysql percona/], sub {
    my ($ver, $bin, $prefix) = @_;
    for_each_log_db_backend(sub {
        my ($backend) = @_;
    my $DRV = ($prefix // '') eq 'percona' ? 'Percona' : 'MySQLCom';
    skipall_unless_can_db(driver => $DRV);

    use File::Temp qw/tempdir/;
    use File::Path qw/make_path/;
    use DBI ();

    use Test2::Harness2::Util::JSON qw/encode_json/;
    use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
    use App::Yath2::Log;
    use App::Yath2::DB;
    # B8 (D6): atomic insert + duplicate-archive rejection.

    my $qdb = get_quiet_db({ driver => $DRV });
    {
    my $admin = DBI->connect(
        $qdb->connect_string, undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    ) or die "connect: $DBI::errstr";
    $admin->do('CREATE DATABASE IF NOT EXISTS yath_log_test_insertatomic');
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

    sub clean_db {
    my $dbh = shift;
    for my $t (qw/
        artifacts subtests job_specs job_tries jobs test_files
        service_lifetimes services runs archives projects
    /) {
        $dbh->do("DELETE FROM $t");
    }
    }

    # {{{ Test 1: duplicate-uuid rejection.
    {
    my $db = App::Yath2::DB->open(dsn => $dsn, flavor => "mysql", backend => $backend);
    $db->bootstrap_schema;
    my $dbh = $db->dbh;
    clean_db($dbh);

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
    # MySQL.pm has its own insert() override that calls
    # _mysql_insert_body which itself calls _populate_summary_rows. The
    # monkey-patch is portable because we patch the base-class symbol
    # inherited by both flavors.
    {
    my $db = App::Yath2::DB->open(dsn => $dsn, flavor => "mysql", backend => $backend);
    $db->bootstrap_schema;
    my $dbh = $db->dbh;
    clean_db($dbh);

    my $src = build_source();

    no warnings 'redefine';
    my $orig = \&App::Yath2::DB::Internal::_populate_summary_rows;
    local *App::Yath2::DB::Internal::_populate_summary_rows = sub {
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

    local *App::Yath2::DB::Internal::_populate_summary_rows = $orig;
    my $aid = eval { $db->insert(App::Yath2::Log->new(dir => $src)) };
    ok(defined $aid, 'retry after rollback succeeds');
    my ($n) = $dbh->selectrow_array(q{SELECT count(*) FROM archives});
    is($n, 1, 'one archives row after retry');
    }
    # }}}

    # {{{ Test 3: explicit archive_uuid override.
    {
    my $db = App::Yath2::DB->open(dsn => $dsn, flavor => "mysql", backend => $backend);
    $db->bootstrap_schema;
    my $dbh = $db->dbh;
    clean_db($dbh);

    my $src_uuid = '019D2B1A-8000-7000-8000-CAFEBABE3001';
    my $ovr_uuid = '019D2B1A-8000-7000-8000-CAFEBABE3002';
    my $src      = build_source(archive_uuid => $src_uuid);

    my $aid = $db->insert(
        App::Yath2::Log->new(dir => $src),
        archive_uuid => $ovr_uuid,
    );
    ok(defined $aid, 'override insert succeeds');

    # MySQL stores BINARY(16). HEX() the column and reformat to a
    # canonical hyphenated string (the *_string companion column is
    # populated by a BIN_TO_UUID() trigger on real MySQL but not when
    # the test backend is mariadbd-via-mysqld -- which QuickDB's
    # MySQL driver typically is on Linux).
    my ($hex) = $dbh->selectrow_array(
        q{SELECT HEX(archive_uuid) FROM archives WHERE archive_id = ?},
        undef, $aid,
    );
    my $got = join('-',
        substr($hex,  0, 8),
        substr($hex,  8, 4),
        substr($hex, 12, 4),
        substr($hex, 16, 4),
        substr($hex, 20, 12),
    );
    is(uc($got), uc($ovr_uuid),
        'override archive_uuid wins over source meta (D6)');
    }
    # }}}

    });
});

done_testing;

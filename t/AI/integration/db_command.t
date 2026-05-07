use Test2::V0;
use warnings;

use App::Yath2::Command::db;

# Smoke tests for the `yath db` command. We exercise the small pure
# helpers (flavor / version parsing, natural version comparator,
# bin-dir resolution) in isolation. End-to-end testing of the full
# command requires DBIx::QuickDB plus a real DB driver and an
# interactive shell on PATH, so the QuickDB / shell drop-in path is
# covered manually.

subtest 'flavor parse' => sub {
    is(
        [App::Yath2::Command::db::_parse_flavor('mariadb')],
        ['mariadb', U()],
        'bare flavor',
    );
    is(
        [App::Yath2::Command::db::_parse_flavor('postgres')],
        ['postgres', U()],
        'bare postgres',
    );
    is(
        [App::Yath2::Command::db::_parse_flavor('postgresql')],
        ['postgresql', U()],
        'postgresql passes through (caller normalises later)',
    );
    is(
        [App::Yath2::Command::db::_parse_flavor('postgres-15')],
        ['postgres', '15'],
        'postgres-15',
    );
    is(
        [App::Yath2::Command::db::_parse_flavor('mariadb-12.2')],
        ['mariadb', '12.2'],
        'mariadb-12.2',
    );
    is(
        [App::Yath2::Command::db::_parse_flavor('MySQL-9.7')],
        ['mysql', '9.7'],
        'flavor lower-cased',
    );
};

subtest 'flavor meta' => sub {
    my @postgres = App::Yath2::Command::db::_flavor_meta('postgres');
    is($postgres[0], 'PostgreSQL',                   'postgres -> PostgreSQL driver');
    is($postgres[1], 'postgresql',                   'postgres -> postgresql prefix');
    is($postgres[2], 'psql',                         'postgres shell');
    is($postgres[4], 'App::Yath2::Log::Postgres',    'postgres backend class');
    is($postgres[5], 0,                              'postgres does not need create db');

    my @postgresql = App::Yath2::Command::db::_flavor_meta('postgresql');
    is($postgresql[0], 'PostgreSQL', 'postgresql alias resolves');

    my @mariadb = App::Yath2::Command::db::_flavor_meta('mariadb');
    is($mariadb[0], 'MariaDB',                     'mariadb driver');
    is($mariadb[2], 'mariadb',                     'mariadb shell');
    is($mariadb[3], ['mysql'],                     'mariadb falls back to mysql');
    is($mariadb[4], 'App::Yath2::Log::MariaDB',    'mariadb backend class');
    is($mariadb[5], 1,                             'mariadb needs create db');

    my @mysql = App::Yath2::Command::db::_flavor_meta('mysql');
    is($mysql[0], 'MySQL',                       'mysql driver');
    is($mysql[4], 'App::Yath2::Log::MySQL',      'mysql backend class');

    my @percona = App::Yath2::Command::db::_flavor_meta('percona');
    is($percona[0], 'Percona',                       'percona driver');
    is($percona[4], 'App::Yath2::Log::MySQL',        'percona reuses mysql backend');

    like(
        dies { App::Yath2::Command::db::_flavor_meta('sqlite') },
        qr/unsupported flavor 'sqlite'/,
        'sqlite is rejected',
    );
};

subtest 'version compare' => sub {
    is(App::Yath2::Command::db::_versioncmp('10.6', '12.2'),  -1, '10.6 < 12.2 numerically (not string)');
    is(App::Yath2::Command::db::_versioncmp('12.2', '10.6'),   1, '12.2 > 10.6 numerically');
    is(App::Yath2::Command::db::_versioncmp('17.9', '17.9'),   0, 'equal');
    is(App::Yath2::Command::db::_versioncmp('15',   '15.17'), -1, '15 < 15.17');
    is(App::Yath2::Command::db::_versioncmp('15.0', '15'),     0, '15.0 == 15 (missing components zero-padded)');
    is(App::Yath2::Command::db::_versioncmp('15.1', '15'),     1, '15.1 > 15');
};

subtest 'resolve_bin_dir' => sub {
    use File::Temp qw/tempdir/;
    use File::Path qw/make_path/;

    my $home = tempdir(CLEANUP => 1);
    local $ENV{HOME} = $home;

    # No ~/dbs at all.
    is(
        App::Yath2::Command::db::_resolve_bin_dir('mariadb', undef),
        U(),
        'missing ~/dbs returns undef (fall back to PATH)',
    );

    make_path("$home/dbs/mariadb-10.6/bin");
    make_path("$home/dbs/mariadb-12.2/bin");
    make_path("$home/dbs/postgresql-17.9/bin");
    make_path("$home/dbs/postgresql-15.17/bin");

    is(
        App::Yath2::Command::db::_resolve_bin_dir('mariadb', undef),
        "$home/dbs/mariadb-12.2/bin",
        'highest mariadb selected',
    );
    is(
        App::Yath2::Command::db::_resolve_bin_dir('postgresql', undef),
        "$home/dbs/postgresql-17.9/bin",
        'highest postgresql selected',
    );
    is(
        App::Yath2::Command::db::_resolve_bin_dir('mariadb', '10.6'),
        "$home/dbs/mariadb-10.6/bin",
        'exact version match',
    );
    is(
        App::Yath2::Command::db::_resolve_bin_dir('postgresql', '15'),
        "$home/dbs/postgresql-15.17/bin",
        'prefix version match (15 -> 15.17)',
    );

    like(
        dies { App::Yath2::Command::db::_resolve_bin_dir('mariadb', '99') },
        qr/no \$HOME\/dbs entry matches 'mariadb-99'/,
        'explicit unmatched version croaks',
    );

    is(
        App::Yath2::Command::db::_resolve_bin_dir('mysql', undef),
        U(),
        'unmatched bare prefix returns undef (PATH fallback)',
    );
};

subtest 'parse args - missing flavor and missing archive' => sub {
    my $cmd = App::Yath2::Command::db->new(
        settings    => undef,
        args        => [],
        env_vars    => {},
        option_state => {},
        plugins     => [],
    );
    like(dies { $cmd->run }, qr/missing FLAVOR argument/, 'no args -> missing flavor');

    $cmd = App::Yath2::Command::db->new(
        settings    => undef,
        args        => ['mariadb'],
        env_vars    => {},
        option_state => {},
        plugins     => [],
    );
    like(dies { $cmd->run }, qr/at least one ARCHIVE argument is required/,
        'flavor without archive');

    $cmd = App::Yath2::Command::db->new(
        settings    => undef,
        args        => ['mariadb', '/no/such/archive.yath'],
        env_vars    => {},
        option_state => {},
        plugins     => [],
    );
    like(dies { $cmd->run }, qr/archive '\Q\/no\/such\/archive.yath\E' does not exist/,
        'nonexistent archive');
};

done_testing;

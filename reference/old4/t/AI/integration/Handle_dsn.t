use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2;
use Test2::Harness2::Util::JSON qw/decode_json/;

sub _new_path {
    return File::Spec->catfile(tempdir(CLEANUP => 1), 'd.t2h2');
}

sub _try_quickdb {
    my ($label, $driver) = @_;
    require DBIx::QuickDB;
    my $instance = eval { DBIx::QuickDB->build_db($label, {driver => $driver}) };
    return $instance unless $@;
    return undef;
}

subtest sidecar_is_json_for_non_sqlite_dsn => sub {
    my $instance = _try_quickdb("t2h2_sidecar_pg", 'PostgreSQL');
    skip_all "PostgreSQL driver unavailable: $@" unless $instance;

    my $path = _new_path();
    my $h    = Test2::Harness2->new(
        dsn     => $instance->connect_string,
        flavor  => 'postgres',
        path    => $path,
        project => 'sidecar-proj',
    );

    isa_ok($h, 'Test2::Harness2');
    is($h->flavor, 'postgres');
    ok(-e $path, 'sidecar file created');

    open(my $fh, '<', $path) or die "open: $!";
    local $/;
    my $bytes = <$fh>;
    close($fh);

    my $info = decode_json($bytes);
    is($info->{flavor},  'postgres');
    is($info->{project}, 'sidecar-proj');
    is($info->{pid},     $$);
    is($info->{user},    $h->user);
    is($info->{host},    $h->host);
    is($info->{cwd},     $h->cwd);
    is($info->{dsn},     $h->dsn);
    ok($info->{started}, 'started timestamp present');

    $h->disconnect;
    ok(!-e $path, 'sidecar removed on disconnect');
};

subtest postgres_bulk_insert_returning => sub {
    my $instance = _try_quickdb("t2h2_bulk_pg", 'PostgreSQL');
    skip_all "PostgreSQL driver unavailable: $@" unless $instance;

    my $h = Test2::Harness2->new(
        dsn     => $instance->connect_string,
        flavor  => 'postgres',
        path    => _new_path(),
        project => 'p',
    );

    my @rows = $h->insert(users =>
        {name => 'a1'}, {name => 'a2'}, {name => 'a3'}, {name => 'a4'},
    );
    is(scalar(@rows), 4, 'four rows back');
    my @ids = map { $_->user_id } @rows;
    ok($ids[0] > 0, 'first id assigned');
    is($ids[1] - $ids[0], 1, 'ids contiguous (1)');
    is($ids[2] - $ids[1], 1, 'ids contiguous (2)');
    is($ids[3] - $ids[2], 1, 'ids contiguous (3)');

    my @all = $h->fetch_all(users => );
    is(scalar(@all), 4, 'four readable');

    $h->disconnect;
};

subtest mariadb_quickdb_full_lifecycle => sub {
    my $instance = _try_quickdb("t2h2_mariadb", 'MariaDB');
    skip_all "MariaDB driver unavailable: $@" unless $instance;

    my $h = Test2::Harness2->new(
        dsn     => $instance->connect_string,
        flavor  => 'mariadb',
        path    => _new_path(),
        project => 'p',
    );

    my @rows = $h->insert(users =>
        {name => 'm1'}, {name => 'm2'}, {name => 'm3'},
    );
    is(scalar(@rows), 3, 'three rows');
    my @ids = map { $_->user_id } @rows;
    is($ids[1] - $ids[0], 1, 'ids contiguous');
    is($ids[2] - $ids[1], 1);

    my $u = $h->fetch(users => name => 'm2');
    ok($u, 'fetched by name');
    is($u->user_id, $ids[1]);

    $h->disconnect;
};

subtest ephemeral_driver_arg_spins_up_quickdb => sub {
    my $h = eval {
        Test2::Harness2->new(
            driver  => 'PostgreSQL',
            path    => _new_path(),
            project => 'p',
        );
    };
    skip_all "PostgreSQL ephemeral failed: $@" unless $h;

    is($h->flavor, 'postgres', 'flavor inferred from driver');
    like($h->dsn, qr/^dbi:Pg:/, 'dsn is postgres');

    my ($u) = $h->insert(users => {name => 'ephem'});
    ok($u->user_id, 'insert works against ephemeral');

    $h->disconnect;
};

subtest reconnect_via_sidecar => sub {
    my $instance = _try_quickdb("t2h2_reconn", 'PostgreSQL');
    skip_all "PostgreSQL driver unavailable: $@" unless $instance;

    my $path = _new_path();
    my $h1   = Test2::Harness2->new(
        dsn     => $instance->connect_string,
        flavor  => 'postgres',
        path    => $path,
        project => 'reconn',
    );

    my ($u) = $h1->insert(users => {name => 'reconnected'});
    my $uid = $u->user_id;

    $h1->{_owns_file} = 0;
    undef $h1;

    ok(-e $path, 'sidecar preserved');

    my $h2 = Test2::Harness2->connect(path => $path, project => 'reconn');
    is($h2->flavor, 'postgres', 'flavor recovered from sidecar');
    like($h2->dsn,  qr/^dbi:Pg:/, 'dsn recovered from sidecar');

    my $u2 = $h2->fetch(users => user_id => $uid);
    ok($u2, 'row still there');
    is($u2->name, 'reconnected');

    $h2->{_owns_file} = 1;
    $h2->disconnect;
};

subtest flavor_detection_from_dsn => sub {
    is(Test2::Harness2->_flavor_from_dsn('dbi:Pg:dbname=x'),      'postgres');
    is(Test2::Harness2->_flavor_from_dsn('dbi:MariaDB:dbname=x'), 'mariadb');
    is(Test2::Harness2->_flavor_from_dsn('dbi:mysql:dbname=x'),   'mysql');
    is(Test2::Harness2->_flavor_from_dsn('dbi:SQLite:dbname=x'),  'sqlite');
    is(Test2::Harness2->_flavor_from_dsn('dbi:Unknown:'),         undef);
    is(Test2::Harness2->_flavor_from_dsn(undef),                  undef);
};

done_testing;

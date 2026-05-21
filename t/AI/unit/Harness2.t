use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use DBI ();

use Test2::Harness2;

sub _path { File::Spec->catfile(tempdir(CLEANUP => 1), shift) }

subtest new_creates_file_and_schema => sub {
    my $path = _path('a.t2h2');
    ok(!-e $path, 'path does not exist yet');

    my $h = Test2::Harness2->new(path => $path, project => 'p1');
    isa_ok($h, 'Test2::Harness2');
    ok(-e $path, 'harness file exists');
    is($h->path, $path);
    is($h->project, 'p1');
    is($h->flavor,  'sqlite');

    my @tables = $h->dbh->selectall_array(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    );
    my %have = map { $_->[0] => 1 } @tables;
    ok($have{collectors}, 'collectors table created');
    ok($have{runs},       'runs table created');
    ok($have{artifacts},  'artifacts table created');

    $h->disconnect;
    ok(!-e $path, 'harness file removed on disconnect');
};

subtest connect_does_not_recreate_schema => sub {
    my $path = _path('b.t2h2');
    my $h = Test2::Harness2->new(path => $path, project => 'p');
    my ($u) = $h->insert(users => {name => 'persisted'});
    my $uid = $u->user_id;
    $h->{_owns_file} = 0;
    undef $h;

    ok(-e $path, 'file preserved');

    my $h2 = Test2::Harness2->connect(path => $path, project => 'p');
    my $u2 = $h2->fetch(users => name => 'persisted');
    ok($u2,                   'row visible after connect');
    is($u2->user_id, $uid,    'same id');

    $h2->{_owns_file} = 1;
    $h2->disconnect;
};

subtest single_insert_returns_id => sub {
    my $path = _path('c.t2h2');
    my $h = Test2::Harness2->new(path => $path, project => 'p');

    my ($row) = $h->insert(users => {name => 'a', email => 'a@x'});
    ok($row->user_id, 'got user_id');
    is($row->name, 'a');
    is($row->email, 'a@x');

    $h->disconnect;
};

subtest bulk_insert_returns_id_range => sub {
    my $path = _path('d.t2h2');
    my $h = Test2::Harness2->new(path => $path, project => 'p');

    my @rows = $h->insert(users =>
        {name => 'u1'}, {name => 'u2'}, {name => 'u3'}, {name => 'u4'},
    );
    is(scalar(@rows), 4, 'four rows');
    my @ids = map { $_->user_id } @rows;
    is($ids[1] - $ids[0], 1, 'ids consecutive (1)');
    is($ids[2] - $ids[1], 1, 'ids consecutive (2)');
    is($ids[3] - $ids[2], 1, 'ids consecutive (3)');

    my @all = $h->fetch_all(users => );
    is(scalar(@all), 4, 'all four readable');

    $h->disconnect;
};

subtest fetch_with_where => sub {
    my $path = _path('e.t2h2');
    my $h = Test2::Harness2->new(path => $path, project => 'p');

    $h->insert(users => {name => 'alpha'});
    $h->insert(users => {name => 'beta'});

    my $row = $h->fetch(users => name => 'beta');
    is($row->name, 'beta', 'fetch by where matched');

    my @all = $h->fetch_all(users => );
    is(scalar(@all), 2, 'fetch_all returns both');

    $h->disconnect;
};

subtest fetch_too_many_croaks => sub {
    my $path = _path('f.t2h2');
    my $h = Test2::Harness2->new(path => $path, project => 'p');

    $h->insert(users => {name => 'a', email => 'x@y'});
    $h->insert(users => {name => 'b', email => 'x@y'});

    like(
        dies { $h->fetch(users => email => 'x@y') },
        qr/more than one/,
        'fetch with multiple matches croaks',
    );

    $h->disconnect;
};

subtest project_is_required => sub {
    my $path = _path('proj.t2h2');
    like(
        dies { Test2::Harness2->new(path => $path) },
        qr/'project' is a required attribute/,
        'missing project croaks',
    );
};

subtest user_required_when_env_missing => sub {
    my $path = _path('user.t2h2');
    local $ENV{USER};
    delete $ENV{USER};
    like(
        dies { Test2::Harness2->new(path => $path, project => 'p') },
        qr/'user' is a required attribute/,
        'missing USER croaks (no silent fallback)',
    );
};

subtest insert_auto_generates_uuid => sub {
    my $path = _path('uuid.t2h2');
    my $h = Test2::Harness2->new(path => $path, project => 'p');

    my ($host) = $h->insert(hosts => {name => 'localhost'});
    my ($user) = $h->insert(users => {name => 'alice'});

    my ($inst) = $h->insert(instances => {
        host_id => $host->host_id,
        user_id => $user->user_id,
        started => 0,
    });
    like($inst->instance_uuid, qr/^[0-9a-f-]{36}$/i, 'instance_uuid auto-generated');

    my $explicit = '11111111-2222-7333-8444-555555555555';
    my ($inst2) = $h->insert(instances => {
        instance_uuid => $explicit,
        host_id       => $host->host_id,
        user_id       => $user->user_id,
        started       => 0,
    });
    is($inst2->instance_uuid, $explicit, 'explicit uuid preserved');

    $h->disconnect;
};

subtest blob_sql_type_returns_dbi_constant => sub {
    my $path = _path('blob.t2h2');
    my $h = Test2::Harness2->new(path => $path, project => 'p');
    is($h->blob_sql_type, DBI::SQL_BLOB(), 'sqlite blob type is DBI::SQL_BLOB');
    $h->disconnect;
};

done_testing;

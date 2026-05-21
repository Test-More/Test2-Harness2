use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2;
use Test2::Harness2::DB::User;

sub _new_harness {
    my $path = File::Spec->catfile(tempdir(CLEANUP => 1), 't.t2h2');
    return Test2::Harness2->new(discovery_path => $path);
}

subtest constants => sub {
    is(Test2::Harness2::DB::User->TABLE,       'users');
    is(Test2::Harness2::DB::User->PRIMARY_KEY, 'user_id');
    is([Test2::Harness2::DB::User->COLUMNS], [qw/user_id name email/]);
};

subtest role_composition => sub {
    ok(
        Test2::Harness2::DB::User->DOES('Test2::Harness2::Role::Row'),
        'DB::User composes Role::Row',
    );
};

subtest save_and_refresh => sub {
    my $h = _new_harness();
    my ($row) = $h->insert(users => {name => 'orig', email => 'a@x'});

    $row->{name}  = 'changed';
    $row->{email} = 'b@y';
    $row->save;

    my $reread = $h->fetch(users => user_id => $row->user_id);
    is($reread->name,  'changed');
    is($reread->email, 'b@y');

    # mutate the row's in-memory copy, then refresh from DB
    $row->{name} = 'in_memory_only';
    $row->refresh;
    is($row->name, 'changed', 'refresh overwrites in-memory mutation');

    $h->disconnect;
};

subtest save_with_hashref => sub {
    my $h = _new_harness();
    my ($row) = $h->insert(users => {name => 'orig', email => 'a@x'});

    $row->save({name => 'updated', email => 'u@x'});
    is($row->name,  'updated', 'in-memory updated by save({...})');
    is($row->email, 'u@x',     'in-memory updated by save({...})');

    my $reread = $h->fetch(users => user_id => $row->user_id);
    is($reread->name,  'updated', 'persisted to DB');
    is($reread->email, 'u@x',     'persisted to DB');

    like(
        dies { $row->save({bogus_col => 1}) },
        qr/'bogus_col' is not a column/,
        'unknown column in hashref croaks',
    );

    like(
        dies { $row->save([]) },
        qr/must be a hashref/,
        'non-hashref arg croaks',
    );

    $h->disconnect;
};

subtest save_requires_pk => sub {
    my $h   = _new_harness();
    my $row = Test2::Harness2::DB::User->new(_handle => $h, name => 'orphan');

    like(
        dies { $row->save },
        qr/no primary key/,
        'save without pk croaks',
    );

    $h->disconnect;
};

subtest refresh_after_external_change => sub {
    my $h = _new_harness();
    my ($row) = $h->insert(users => {name => 'orig'});

    $h->dbh->do("UPDATE users SET email = ? WHERE user_id = ?",
        undef, 'external@x', $row->user_id);

    $row->refresh;
    is($row->email, 'external@x', 'refresh picked up external change');

    $h->disconnect;
};

subtest to_json => sub {
    my $h     = _new_harness();
    my ($row) = $h->insert(users => {name => 'jane', email => 'j@x'});
    my $hash  = $row->TO_JSON;

    is($hash->{name},  'jane');
    is($hash->{email}, 'j@x');
    ok(!exists $hash->{_handle}, 'handle ref not exported');

    $h->disconnect;
};

done_testing;

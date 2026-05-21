use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2;

# Add a custom method to a DB class so we can test symbol-walk delegation.
# Must run at compile time, before the TestLogic::User package's `use
# Test2::Harness2::Util::DBDelegate` (which walks the DB class symbol table
# at compile time).
BEGIN {
    require Test2::Harness2::DB::User;
    no warnings 'once';
    *Test2::Harness2::DB::User::pretty_name = sub {
        my $self = shift;
        return "<<" . $self->{name} . ">>";
    };
}

# A throwaway logic class that wraps Test2::Harness2::DB::User.
{
    package TestLogic::User;
    use strict;
    use warnings;

    use Object::HashBase qw{
        <some_logic_attr
    };

    use Test2::Harness2::Util::DBDelegate 'users';

    sub greet {
        my $self = shift;
        return "hello " . $self->name;
    }

    1;
}

sub _new_harness {
    my $path = File::Spec->catfile(tempdir(CLEANUP => 1), 't.t2h2');
    return Test2::Harness2->new(discovery_path => $path);
}

subtest installed_class_methods => sub {
    is(TestLogic::User->TABLE,    'users');
    is(TestLogic::User->DB_CLASS, 'Test2::Harness2::DB::User');
    is(TestLogic::User->ROW,      'row');
};

subtest row_accessor => sub {
    my $obj = TestLogic::User->new(row => bless {name => 'alice'}, 'Test2::Harness2::DB::User');
    isa_ok($obj->row, ['Test2::Harness2::DB::User']);
    is($obj->{+TestLogic::User::ROW()}, $obj->row, 'ROW constant matches accessor slot');
};

subtest column_delegates_direct_hash => sub {
    my $h     = _new_harness();
    my ($db)  = $h->insert(users => {name => 'alice', email => 'a@x'});
    my $logic = TestLogic::User->new(row => $db);

    is($logic->name,    'alice',         'name delegates directly to row hash');
    is($logic->email,   'a@x',           'email delegates directly to row hash');
    is($logic->user_id, $db->user_id,    'user_id delegates directly to row hash');
    is($logic->greet,   'hello alice',   'logic methods see delegated columns');

    # Bypass the DB row method dispatch by writing the row's hash directly.
    $db->{name} = 'altered';
    is($logic->name, 'altered', 'reader is direct hash access (no method call)');

    $h->disconnect;
};

subtest column_setters_direct_hash => sub {
    my $h     = _new_harness();
    my ($db)  = $h->insert(users => {name => 'alice', email => 'a@x'});
    my $logic = TestLogic::User->new(row => $db);

    $logic->set_name('beth');
    is($db->{name}, 'beth', 'set_name writes directly to row hash');
    is($logic->name, 'beth', 'reader sees the new value');

    $logic->set_email('b@y');
    is($db->{email}, 'b@y');

    $h->disconnect;
};

subtest existing_method_preserved => sub {
    {
        package TestLogic::OverrideName;
        use strict;
        use warnings;

        use Object::HashBase;

        sub name     { 'overridden-name' }
        sub set_name { 'overridden-set'   }

        use Test2::Harness2::Util::DBDelegate 'users';

        1;
    }

    my $db = bless {name => 'alice'}, 'Test2::Harness2::DB::User';
    my $obj = TestLogic::OverrideName->new(row => $db);
    is($obj->name,        'overridden-name', 'pre-existing reader wins');
    is($obj->set_name,    'overridden-set',  'pre-existing setter wins');
};

subtest symbol_walk_delegates_non_columns => sub {
    my $h     = _new_harness();
    my ($db)  = $h->insert(users => {name => 'alice'});
    my $logic = TestLogic::User->new(row => $db);

    can_ok($logic, 'pretty_name');
    is($logic->pretty_name, '<<alice>>', 'symbol-walk picked up pretty_name from DB class');

    $h->disconnect;
};

subtest constants_and_metadata_not_delegated => sub {
    # COLUMNS / TABLE / PRIMARY_KEY are class methods on the row — we install
    # our own TABLE constant in the logic class and DO NOT install delegates
    # for the metadata methods of the row.
    is(TestLogic::User->TABLE, 'users', 'logic class TABLE is own constant');

    # Make sure HashBase column constants (USER_ID, NAME, ...) are NOT installed
    # in the logic class.
    no strict 'refs';
    ok(!defined &{"TestLogic::User::NAME"}, 'NAME constant not delegated');
    ok(!defined &{"TestLogic::User::USER_ID"}, 'USER_ID constant not delegated');
    ok(!defined &{"TestLogic::User::_HANDLE"}, '_HANDLE constant not delegated');
};

subtest save_delegated_with_hashref => sub {
    my $h     = _new_harness();
    my ($db)  = $h->insert(users => {name => 'alice', email => 'a@x'});
    my $logic = TestLogic::User->new(row => $db);

    can_ok($logic, 'save');
    $logic->save({name => 'carol', email => 'c@x'});

    my $reread = $h->fetch(users => user_id => $db->user_id);
    is($reread->name,  'carol');
    is($reread->email, 'c@x');

    $h->disconnect;
};

subtest wrong_table_croaks => sub {
    like(
        dies {
            eval q{
                package TestLogic::Bogus;
                use Test2::Harness2::Util::DBDelegate 'no_such_table';
                1;
            } or die $@;
        },
        qr/could not load|Can't locate/i,
        'bad table name fails to load DB class',
    );
};

done_testing;

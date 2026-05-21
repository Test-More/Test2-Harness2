use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2;

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

subtest column_delegates => sub {
    my $path  = File::Spec->catfile(tempdir(CLEANUP => 1), 't.t2h2');
    my $h     = Test2::Harness2->new(discovery_path => $path);
    my ($db)  = $h->insert(users => {name => 'alice', email => 'a@x'});
    my $logic = TestLogic::User->new(row => $db);

    is($logic->name,    'alice',  'name delegates to row');
    is($logic->email,   'a@x',    'email delegates to row');
    is($logic->user_id, $db->user_id, 'user_id delegates to row');
    is($logic->greet,   'hello alice', 'logic methods see delegated columns');

    $h->disconnect;
};

subtest existing_method_preserved => sub {
    {
        package TestLogic::OverrideName;
        use strict;
        use warnings;

        use Object::HashBase;

        sub name { 'overridden' }

        use Test2::Harness2::Util::DBDelegate 'users';

        1;
    }

    my $db = bless {name => 'alice'}, 'Test2::Harness2::DB::User';
    my $obj = TestLogic::OverrideName->new(row => $db);
    is($obj->name, 'overridden', 'pre-existing method wins, delegate skipped');
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
        qr/could not load .*no_such_table|Can't locate/i,
        'bad table name fails to load DB class',
    );
};

done_testing;

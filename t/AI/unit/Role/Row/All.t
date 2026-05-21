use Test2::V0;

my @classes = qw(
    Test2::Harness2::DB::User
    Test2::Harness2::DB::Host
    Test2::Harness2::DB::Project
    Test2::Harness2::DB::Version
    Test2::Harness2::DB::VcsInfo
    Test2::Harness2::DB::TestFile
    Test2::Harness2::DB::Instance
    Test2::Harness2::DB::Runner
    Test2::Harness2::DB::Collector
    Test2::Harness2::DB::Service
    Test2::Harness2::DB::ServiceState
    Test2::Harness2::DB::Request
    Test2::Harness2::DB::Scheduler
    Test2::Harness2::DB::Resource
    Test2::Harness2::DB::ResourceSnapshot
    Test2::Harness2::DB::Run
    Test2::Harness2::DB::Job
    Test2::Harness2::DB::JobTry
    Test2::Harness2::DB::Artifact
    Test2::Harness2::DB::Coverage
    Test2::Harness2::DB::Launcher
    Test2::Harness2::DB::Launch
);

is(scalar(@classes), 22, '22 DB row classes expected');

for my $class (@classes) {
    (my $file = $class) =~ s{::}{/}g;
    require "$file.pm";

    ok(
        $class->DOES('Test2::Harness2::Role::Row'),
        "$class composes Test2::Harness2::Role::Row",
    );

    can_ok($class, qw/TABLE PRIMARY_KEY COLUMNS new save refresh TO_JSON/);

    my $table = $class->TABLE;
    ok($table && $table =~ /^[a-z_]+$/, "$class->TABLE = $table");

    my $pk = $class->PRIMARY_KEY;
    ok($pk && $pk =~ /^[a-z_]+_id$/, "$class->PRIMARY_KEY = $pk");

    my @cols = $class->COLUMNS;
    ok(scalar(@cols), "$class->COLUMNS has entries");
    ok((grep { $_ eq $pk } @cols), "$class COLUMNS includes the primary key");
}

done_testing;

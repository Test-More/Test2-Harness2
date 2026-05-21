use Test2::V0;

my @classes = qw(
    Test2::Harness2::User
    Test2::Harness2::Host
    Test2::Harness2::Project
    Test2::Harness2::Project::Version
    Test2::Harness2::Project::VcsInfo
    Test2::Harness2::Project::TestFile
    Test2::Harness2::Instance
    Test2::Harness2::Runner
    Test2::Harness2::Runner::Collector
    Test2::Harness2::Runner::Service
    Test2::Harness2::Runner::Service::State
    Test2::Harness2::Runner::Service::Request
    Test2::Harness2::Runner::Scheduler
    Test2::Harness2::Runner::Resource
    Test2::Harness2::Runner::Resource::Snapshot
    Test2::Harness2::Runner::Run
    Test2::Harness2::Runner::Run::Job
    Test2::Harness2::Runner::Run::Job::Try
    Test2::Harness2::Runner::Run::Artifact
    Test2::Harness2::Runner::Run::Coverage
    Test2::Harness2::Runner::Run::Resource
    Test2::Harness2::Launcher
    Test2::Harness2::Launcher::Launch
);

is(scalar(@classes), 23, '23 row classes expected');

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

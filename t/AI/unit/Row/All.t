use Test2::V0;

my @rows = qw(
    Users Hosts Projects Versions Instances Runners Collectors Artifacts
    Runs Services ServiceState Requests TestFiles Jobs JobTries Launchers
    Launches
);

is(scalar(@rows), 17, '17 row classes expected');

for my $r (@rows) {
    my $class = "Test2::Harness2::Row::$r";
    (my $file = $class) =~ s{::}{/}g;
    require "$file.pm";

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

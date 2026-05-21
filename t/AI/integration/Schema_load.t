use Test2::V0;
use FindBin ();
use File::Spec ();
use DBI ();

my $schema_dir = File::Spec->catdir($FindBin::Bin, '..', '..', '..', 'share', 'schema');
$schema_dir = File::Spec->rel2abs($schema_dir);

ok(-d $schema_dir, "schema dir exists: $schema_dir");

my @EXPECTED_TABLES = qw/
    users hosts projects versions vcs_info
    instances runners collectors artifacts
    runs services service_state requests
    test_files jobs job_tries
    launchers launches
    coverage schedulers resources resource_snapshots
/;

sub _load_schema {
    my ($dbh, $path) = @_;
    open(my $fh, '<', $path) or die "open $path: $!";
    local $/;
    my $sql = <$fh>;
    close($fh);

    $sql =~ s{^\s*--[^\n]*\n}{}mg;

    my @stmts = grep { /\S/ } split /;\s*(?:\n|\z)/, $sql;
    for my $stmt (@stmts) {
        $stmt =~ s/^\s+//;
        $stmt =~ s/\s+$//;
        next unless length $stmt;
        $dbh->do($stmt);
    }
    return;
}

sub _verify_tables {
    my ($dbh, $list_sql) = @_;
    my $rows = $dbh->selectall_arrayref($list_sql);
    my %have = map { lc($_->[0]) => 1 } @$rows;
    for my $t (@EXPECTED_TABLES) {
        ok($have{$t}, "table '$t' present");
    }
    return;
}

sub _smoke_insert_users {
    my ($dbh, $sth_returning) = @_;
    $dbh->do("INSERT INTO users (name, email) VALUES (?, ?)",
        undef, 'alice', 'alice@example.com');
    my ($name) = $dbh->selectrow_array("SELECT name FROM users WHERE name = ?", undef, 'alice');
    is($name, 'alice', 'inserted user round-tripped');
}

sub _smoke_mysql_uuid_trigger {
    my ($dbh) = @_;

    $dbh->do("INSERT INTO hosts (name) VALUES ('h1')");
    my ($host_id) = $dbh->selectrow_array("SELECT host_id FROM hosts WHERE name = 'h1'");

    $dbh->do("INSERT INTO users (name, email) VALUES ('bob', 'bob\@example.com')");
    my ($user_id) = $dbh->selectrow_array("SELECT user_id FROM users WHERE name = 'bob'");

    my $uuid_bytes = "\x01\x02\x03\x04\x05\x06\x77\x08\x90\xab\xcd\xef\x12\x34\x56\x78";
    my $sth = $dbh->prepare(
        "INSERT INTO instances (instance_uuid, host_id, user_id, started) VALUES (?, ?, ?, ?)"
    );
    $sth->bind_param(1, $uuid_bytes, DBI::SQL_BINARY());
    $sth->bind_param(2, $host_id);
    $sth->bind_param(3, $user_id);
    $sth->bind_param(4, 12345.6);
    $sth->execute;

    my ($got) = $dbh->selectrow_array(
        "SELECT instance_uuid_string FROM instances WHERE host_id = ?", undef, $host_id,
    );
    is(
        $got,
        '01020304-0506-7708-90ab-cdef12345678',
        'BEFORE INSERT trigger populates instance_uuid_string',
    );
}

sub _smoke_mariadb_uuid_native {
    my ($dbh) = @_;

    $dbh->do("INSERT INTO hosts (name) VALUES ('h1')");
    my ($host_id) = $dbh->selectrow_array("SELECT host_id FROM hosts WHERE name = 'h1'");

    $dbh->do("INSERT INTO users (name, email) VALUES ('bob', 'bob\@example.com')");
    my ($user_id) = $dbh->selectrow_array("SELECT user_id FROM users WHERE name = 'bob'");

    my $uuid = '01020304-0506-7708-90ab-cdef12345678';
    $dbh->do(
        "INSERT INTO instances (instance_uuid, host_id, user_id, started) VALUES (?, ?, ?, ?)",
        undef, $uuid, $host_id, $user_id, 12345.6,
    );

    my ($got) = $dbh->selectrow_array(
        "SELECT instance_uuid FROM instances WHERE host_id = ?", undef, $host_id,
    );
    is($got, $uuid, 'MariaDB native UUID column round-trips canonical 36-char string');
}

subtest sqlite => sub {
    require DBIx::QuickDB;
    my $db  = DBIx::QuickDB->build_db('sqlite_smoke', {driver => 'SQLite'});
    my $dbh = $db->connect;

    _load_schema($dbh, File::Spec->catfile($schema_dir, 'sqlite.sql'));
    _verify_tables($dbh, q{SELECT name FROM sqlite_master WHERE type = 'table'});
    _smoke_insert_users($dbh);

    $dbh->disconnect;
};

for my $flavor (
    {file => 'postgres.sql', driver => 'PostgreSQL',
     list => q{SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'}},
    {file => 'mysql.sql',    driver => 'MySQL',
     list => q{SELECT TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA = DATABASE()}},
    {file => 'mariadb.sql',  driver => 'MariaDB',
     list => q{SELECT TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA = DATABASE()}},
    {file => 'percona.sql',  driver => 'Percona',
     list => q{SELECT TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA = DATABASE()}},
) {
    my $name = lc $flavor->{driver};

    subtest $name => sub {
        require DBIx::QuickDB;

        my $db = eval {
            DBIx::QuickDB->build_db("${name}_smoke", {driver => $flavor->{driver}});
        };
        my $err = $@;

        skip_all "$flavor->{driver} driver unavailable in this environment: $err"
            unless $db;

        my $dbh = eval { $db->connect };
        skip_all "$flavor->{driver} connect failed: $@"
            unless $dbh;

        _load_schema($dbh, File::Spec->catfile($schema_dir, $flavor->{file}));
        _verify_tables($dbh, $flavor->{list});
        _smoke_insert_users($dbh);
        _smoke_mysql_uuid_trigger($dbh)  if $flavor->{driver} =~ /^(MySQL|Percona)$/;
        _smoke_mariadb_uuid_native($dbh) if $flavor->{driver} eq 'MariaDB';

        $dbh->disconnect;
    };
}

done_testing;

use Test2::V0;

use FindBin qw/$Bin/;
use File::Spec ();

use App::Yath2::DB::DBIC::Schema;

# Locate share/schema/sqlite.sql relative to this test file. The test
# may run from any cwd (yath -D test does not chdir to repo root).
my $sql_path;
{
    my $dir = $Bin;
    for (1 .. 8) {
        my $cand = File::Spec->catfile($dir, 'share', 'schema', 'sqlite.sql');
        if (-e $cand) {
            $sql_path = $cand;
            last;
        }
        $dir = File::Spec->catdir($dir, File::Spec->updir);
    }
}
ok( defined $sql_path && -e $sql_path,
    "found share/schema/sqlite.sql at $sql_path" )
    or skip_all "could not locate share/schema/sqlite.sql";

open(my $fh, '<', $sql_path) or die "open '$sql_path': $!";
my $sql = do { local $/; <$fh> };
close $fh;

# Parse `CREATE TABLE <name> ( ... );` blocks. Pull column-name from
# each non-constraint line. Skip CHECK / UNIQUE / FOREIGN KEY /
# PRIMARY KEY constraints.
my %sql_tables;
while ($sql =~ /CREATE\s+TABLE\s+(\w+)\s*\((.+?)\n\);/sg) {
    my ($tab, $body) = ($1, $2);
    my %cols;
    for my $line (split /\n/, $body) {
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next unless length $line;
        next if $line =~ /^--/;
        next if $line =~ /^(?:PRIMARY\s+KEY|UNIQUE|FOREIGN\s+KEY|CHECK)\b/i;
        # Column lines look like:  colname TYPE [constraints],
        # or with quoted column names like:  "user" TEXT,
        if ($line =~ /^"?(\w+)"?\s+/) {
            $cols{$1} = 1;
        }
    }
    $sql_tables{$tab} = \%cols if %cols;
}

ok( scalar(keys %sql_tables) >= 11, "parsed at least 11 CREATE TABLEs from sqlite.sql" );

my $schema = App::Yath2::DB::DBIC::Schema->connect(
    sub { die "no real connection in this test" }
);

my %seen_table;
for my $source (sort $schema->sources) {
    my $rsrc    = $schema->resultset($source)->result_source;
    my $table   = $rsrc->name;
    my %columns = map { $_ => 1 } $rsrc->columns;

    $seen_table{$table} = 1;

    ok( exists $sql_tables{$table},
        "DBIC table '$table' (source $source) appears in sqlite.sql" )
        or next;

    my @missing;
    for my $col (sort keys %{$sql_tables{$table}}) {
        # *_uuid_string is a MySQL-only shadow column populated by
        # triggers (per the schema spec). It does not appear in
        # sqlite.sql -- the allowlist is documentation-only.
        next if $col =~ /_uuid_string$/;
        push @missing, $col unless $columns{$col};
    }

    is( \@missing, [],
        "DBIC source $source ($table) has every column declared in sqlite.sql" )
        or diag "Missing in DBIC: @missing";
}

# Reverse coverage: every CREATE TABLE in sqlite.sql should be modeled.
for my $table (sort keys %sql_tables) {
    ok( $seen_table{$table}, "sqlite.sql table '$table' is modeled by some Result class" );
}

done_testing;

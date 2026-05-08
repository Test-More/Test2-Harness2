use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Util::UUID qw/gen_uuid/;

use App::Yath2::DB;

my $dir = tempdir(CLEANUP => 1);
my $db = App::Yath2::DB->open(file => "$dir/test.yath");
$db->bootstrap_schema;

is($db->archive_count, 0, 'no archives yet');

# Insert an archive directly via dbh so we can test scoped().
my $u = gen_uuid();
$db->dbh->do(
    q{INSERT INTO archives (archive_uuid, archive_version) VALUES (?, ?)},
    undef, $u, '2.000012',
);

is($db->archive_count, 1, 'one archive after insert');
ok($db->has_archive($u), 'has_archive sees it');

my $scoped = $db->scoped($u);
isa_ok($scoped, ['App::Yath2::DB::Internal::Sqlite'], 'scoped returns same class');
is($scoped->dbh, $db->dbh, 'scoped shares dbh');
is($scoped->{uuid}, $u, 'scoped sets uuid');

# scoped() without a uuid dies.
my $err = dies { $db->scoped() };
like($err, qr/scoped\(\) requires a uuid/, 'scoped without uuid dies');

done_testing;

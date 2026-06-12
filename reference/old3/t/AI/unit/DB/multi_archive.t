use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir/;
use Test2::Util::UUID qw/gen_uuid/;

use App::Yath2::DB;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

# Multi-archive surface (Group B of App::Yath2::Role::DB::Backend) ought
# to behave identically across both backends. We exercise that contract
# here against a sqlite file -- the same archives / archive_count /
# has_archive / scoped surface is used by every server-flavored backend
# too, and the role keeps the implementations aligned.

for_each_log_db_backend(sub {
    my ($backend) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $db = App::Yath2::DB->open(file => "$dir/multi.yath", backend => $backend);
    $db->bootstrap_schema;

    is($db->archive_count, 0, 'starts empty');
    is([$db->archives],   [], 'archives list empty');

    my @uuids = (gen_uuid(), gen_uuid(), gen_uuid());
    my $version = '2.000012';
    for my $u (@uuids) {
        $db->dbh->do(
            q{INSERT INTO archives (archive_uuid, archive_version) VALUES (?, ?)},
            undef, $u, $version,
        );
    }

    is($db->archive_count, 3, 'three archives');
    # archives() returns canonical lowercase hex; compare on lc() so
    # the test is independent of gen_uuid()'s native case.
    is(
        [sort $db->archives],
        [sort map { lc } @uuids],
        'archives lists all UUIDs',
    );

    ok($db->has_archive($uuids[1]), 'has_archive true for present');
    ok(!$db->has_archive(gen_uuid()), 'has_archive false for absent');

    my $scoped = $db->scoped($uuids[0]);
    ok(defined $scoped, 'scoped returns an instance');
    is($scoped->dbh, $db->dbh, 'scoped shares dbh');

    my $err = dies { $db->scoped() };
    like($err, qr/scoped\(\) requires a uuid/, 'scoped without uuid dies');
});

done_testing;

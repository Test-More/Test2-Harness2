use Test2::V0;
use File::Temp qw/tempdir/;

use App::Yath2::DB;

my $dir = tempdir(CLEANUP => 1);

my $db = App::Yath2::DB->open(file => "$dir/empty.yath");
isa_ok($db, ['App::Yath2::DB::Internal::Sqlite'], 'file => routes to sqlite');

# DSN-based dispatch: don't actually connect, just verify the class path.
# Use a non-existent DSN that will die at connect; we only want the
# class resolution to happen first.
my $err = dies {
    App::Yath2::DB->open(dsn => 'dbi:Pg:host=127.0.0.1;dbname=__nope__', backend => 'internal');
};
# May die during connect; we only care that no "unknown flavor" error.
unlike($err // '', qr/unknown internal flavor/, 'pg DSN routes to postgres class');

# Bogus DSN dies cleanly.
$err = dies {
    App::Yath2::DB->open(dsn => 'dbi:Bogus:x', backend => 'internal');
};
like($err, qr/could not detect flavor from DSN/, 'bogus DSN dies clearly');

done_testing;

use Test2::V0;

ok( lives { require App::Yath2::DB }, 'loads App::Yath2::DB' )
    or diag $@;

# Default backend is 'internal'.
my $err = dies { App::Yath2::DB->open() };
like($err, qr/file.*dsn.*dbh/i, 'open() with no source dies clearly');

# Explicit unknown backend dies.
$err = dies { App::Yath2::DB->open(file => '/tmp/bogus.yath', backend => 'nope') };
like($err, qr/unknown backend 'nope'/, 'unknown backend dies');

done_testing;

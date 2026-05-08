use Test2::V0;

ok( lives { require App::Yath2::DB }, 'loads App::Yath2::DB' )
    or diag $@;

# new() with no source dies clearly.
my $err = dies { App::Yath2::DB->new() };
like($err, qr/file.*dsn.*dbh/i, 'new() with no source dies clearly');

# Explicit unknown backend dies.
$err = dies { App::Yath2::DB->new(file => '/tmp/bogus.yath', backend => 'nope') };
like($err, qr/unknown backend 'nope'/, 'unknown backend dies');

# 'internal' is no longer accepted.
$err = dies { App::Yath2::DB->new(file => '/tmp/bogus.yath', backend => 'internal') };
like($err, qr/unknown backend 'internal'/, 'internal backend rejected (use sql or dbic)');

# open() is preserved as a back-compat alias for new().
$err = dies { App::Yath2::DB->open() };
like($err, qr/file.*dsn.*dbh/i, 'open() forwards to new()');

done_testing;

use Test2::V0;

use App::Yath2::Log;

# Sqlite: stub class loads and throws on every method.
{
    require App::Yath2::Log::Sqlite;
    my $log = App::Yath2::Log::Sqlite->new(file => '/dev/null/no.sqlite');
    isa_ok($log, ['App::Yath2::Log::Sqlite']);

    like(dies { $log->services }, qr/not yet implemented/, 'sqlite services stub');
    like(dies { $log->runs },     qr/not yet implemented/, 'sqlite runs stub');
}

done_testing;

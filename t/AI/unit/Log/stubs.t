use Test2::V0;
use File::Temp qw/tempdir tempfile/;

use App::Yath2::Log;

# TarZIdx: reader API is stubbed in M2 step 10a; methods throw.
{
    my $src = tempdir(CLEANUP => 1);
    my (undef, $out) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $out;

    require App::Yath2::Log::TarZIdx;
    App::Yath2::Log::TarZIdx->new(path => $out)->_write_from_directory($src);

    my $log = App::Yath2::Log->new(file => $out);
    isa_ok($log, ['App::Yath2::Log::TarZIdx']);

    like(dies { $log->services }, qr/not yet implemented/, 'services stub');
    like(dies { $log->runs }, qr/not yet implemented/,     'runs stub');
    like(dies { $log->event(0) }, qr/not yet implemented/, 'event stub');
    like(dies { $log->artifacts }, qr/not yet implemented/, 'artifacts stub');
}

# Sqlite: stub class loads and throws on every method.
{
    require App::Yath2::Log::Sqlite;
    my $log = App::Yath2::Log::Sqlite->new(file => '/dev/null/no.sqlite');
    isa_ok($log, ['App::Yath2::Log::Sqlite']);

    like(dies { $log->services }, qr/not yet implemented/, 'sqlite services stub');
    like(dies { $log->runs },     qr/not yet implemented/, 'sqlite runs stub');
}

done_testing;

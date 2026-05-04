use Test2::V0;
use File::Temp qw/tempdir tempfile/;

use App::Yath2::Log;

# live => $dir
{
    my $dir = tempdir(CLEANUP => 1);
    my $log = App::Yath2::Log->new(live => $dir);
    isa_ok($log, ['App::Yath2::Log::Live']);
    is($log->is_live, 1, 'live backend');
}

# dir => $dir
{
    my $dir = tempdir(CLEANUP => 1);
    my $log = App::Yath2::Log->new(dir => $dir);
    isa_ok($log, ['App::Yath2::Log::Directory']);
    is($log->is_live, 0, 'sealed backend');
}

# file => $tar
{
    # Build a synthetic tar.zidx archive from an empty source dir.
    my $src = tempdir(CLEANUP => 1);
    my (undef, $out) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $out;

    require App::Yath2::Log::TarZIdx;
    my $arc = App::Yath2::Log::TarZIdx->new(path => $out);
    $arc->_write_from_directory($src);

    ok(-s $out, 'tar.zidx output non-empty');

    my $log = App::Yath2::Log->new(file => $out);
    isa_ok($log, ['App::Yath2::Log::TarZIdx']);
}

# Mutually exclusive args.
like(
    dies { App::Yath2::Log->new(live => '/tmp', dir => '/tmp') },
    qr/mutually exclusive/i,
    'live + dir conflict',
);

# Missing required arg.
like(
    dies { App::Yath2::Log->new() },
    qr/requires one of/i,
    'no args -> error',
);

# Bad file path.
like(
    dies { App::Yath2::Log->new(file => '/nonexistent/path.yath') },
    qr/does not exist/,
    'missing file -> error',
);

done_testing;

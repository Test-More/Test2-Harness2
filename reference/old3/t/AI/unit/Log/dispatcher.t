use Test2::V0;
use File::Temp qw/tempdir/;

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
    my $work = tempdir(CLEANUP => 1);
    my $out = "$work/empty.yath";

    require App::Yath2::Log::TarZIdx;
    my $arc = App::Yath2::Log::TarZIdx->new(path => $out);
    my $meta = App::Yath2::Log->build_archive_meta;
    my $meta_bytes = App::Yath2::Log->encode_archive_meta($meta);
    $arc->_write_from_directory(
        $src,
        meta_json_bytes => $meta_bytes,
        extra_files     => { App::Yath2::Log->META_FILENAME() => $meta_bytes },
    );

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

use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use FindBin ();
use File::Spec ();

use App::Yath2::LogArchive;
use App::Yath2::Command::archive;
use App::Yath2::Command::extract;
use Test2::Harness2::Util::JSON qw/decode_json write_json_zst_file_atomic/;
use Test2::Harness2::Util::Zstd qw/compress_blob compress_file_atomic/;

my $repo_dict = File::Spec->catfile(
    $FindBin::Bin, '..', '..', '..', 'share', 'other', 'zstd.dict',
);

# Build a small logdir-shaped tree with a .json.zst artifact, a
# .jsonl.zst event stream, a verbatim binary file, and a
# zstd-dict.bin so the writer bundles a dict.
sub _make_logdir {
    my %opts = @_;
    my $dir  = tempdir(CLEANUP => 1);
    mkdir "$dir/services" or die $!;

    # A compressed snapshot, dict-aware.
    compress_file_atomic(
        "$dir/services/harness.json.zst",
        qq[{"kind":"harness","run_id":"R"}],
        ($opts{dict_path} ? (dict_path => $opts{dict_path}) : ()),
    );

    # A jsonl stream: two frames each compressed standalone.
    my $event = compress_blob(
        qq[{"event":"a"}\n],
        ($opts{dict_path} ? (dict_path => $opts{dict_path}) : ()),
    );
    open my $fh, '>', "$dir/services/harness.jsonl.zst" or die $!;
    binmode $fh;
    print $fh $event x 2;
    close $fh;

    # Bundled dict copy.
    if ($opts{dict_path}) {
        require File::Copy;
        File::Copy::cp($opts{dict_path}, "$dir/zstd-dict.bin")
            or die "cp dict: $!";
    }

    # Manifest keyed by '.zst' paths -- the live logdir shape.
    write_json_zst_file_atomic(
        "$dir/artifacts.json.zst",
        {
            'services/harness.json.zst'  => 'Test2::Harness2::Collector::Logger::JSON',
            'services/harness.jsonl.zst' => 'Test2::Harness2::Collector::Logger::JSONL',
        },
        ($opts{dict_path} ? (dict_path => $opts{dict_path}) : ()),
    );

    return $dir;
}

sub _run_cmd {
    my ($class, @args) = @_;
    my $cmd = $class->new(args => [@args], settings => {});
    my $out = '';
    my $orig = select;
    open(my $cap, '>', \$out) or die $!;
    select $cap;
    my $rc = eval { $cmd->run };
    my $err = $@;
    select $orig;
    close $cap;
    return ($rc, $out, $err);
}

subtest 'archive + extract (default decompresses)' => sub {
    plan skip_all => "dict not present" unless -f $repo_dict;

    my $logdir = _make_logdir(dict_path => $repo_dict);
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my (undef, undef, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive: no exception');

    my $dest = "$work/restored";
    (undef, undef, $err) = _run_cmd('App::Yath2::Command::extract', $arc, $dest);
    is($err, '', 'extract: no exception');

    # .zst suffix stripped from output
    ok(-f "$dest/services/harness.json",  'json snapshot extracted plaintext');
    ok(-f "$dest/services/harness.jsonl", 'jsonl stream extracted plaintext');
    ok(!-f "$dest/services/harness.json.zst",
        'no .zst suffix on output');

    # Dict copy lands at zstd-dict.bin (no rename, no .zst suffix issue)
    ok(-f "$dest/zstd-dict.bin", 'bundled dict written out verbatim');

    # Plaintext content is human-readable
    open my $rfh, '<', "$dest/services/harness.json" or die $!;
    my $body = do { local $/; <$rfh> };
    close $rfh;
    like($body, qr/"kind":"harness"/, 'json content readable');

    # Manifest keys had .zst stripped to match extracted filenames.
    open my $mfh, '<', "$dest/artifacts.json" or die $!;
    my $manifest = decode_json(do { local $/; <$mfh> });
    close $mfh;
    is(
        $manifest,
        {
            'services/harness.json'  => 'Test2::Harness2::Collector::Logger::JSON',
            'services/harness.jsonl' => 'Test2::Harness2::Collector::Logger::JSONL',
        },
        'manifest keys rewritten with .zst stripped',
    );

    # The extracted tree is itself a valid Directory-shape archive
    # (yath replay /tmp/extracted/ should work).
    my $la = App::Yath2::LogArchive->new(path => $dest);
    is(
        $la->artifacts,
        $manifest,
        'LogArchive::Directory reads the plaintext manifest of an extracted tree',
    );
};

subtest 'archive + extract --no-decompress preserves .zst' => sub {
    plan skip_all => "dict not present" unless -f $repo_dict;

    my $logdir = _make_logdir(dict_path => $repo_dict);
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my (undef, undef, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive: no exception');

    my $dest = "$work/restored_raw";
    (undef, undef, $err) = _run_cmd('App::Yath2::Command::extract', '--no-decompress', $arc, $dest);
    is($err, '', 'extract: no exception');

    ok(-f "$dest/services/harness.json.zst",  'json.zst preserved');
    ok(-f "$dest/services/harness.jsonl.zst", 'jsonl.zst preserved');
    ok(-f "$dest/zstd-dict.bin",              'bundled dict preserved');
    ok(!-f "$dest/services/harness.json",
        'no plaintext json when --no-decompress');
};

subtest 'archive + extract dict-less' => sub {
    my $logdir = _make_logdir();
    my $work   = tempdir(CLEANUP => 1);
    my $arc    = "$work/out.yath";

    my (undef, undef, $err) = _run_cmd('App::Yath2::Command::archive', $logdir, $arc);
    is($err, '', 'archive: no exception');

    # The reader must not loop hunting for a dict; a missing
    # zstd-dict.bin is the authoritative "dict-less" signal.
    my $dest = "$work/restored_nodict";
    (undef, undef, $err) = _run_cmd('App::Yath2::Command::extract', $arc, $dest);
    is($err, '', 'extract: no exception');

    ok(-f "$dest/services/harness.json",   'json extracted');
    ok(!-f "$dest/zstd-dict.bin",          'no zstd-dict.bin in extracted tree');
};

done_testing;

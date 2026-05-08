# HARNESS-CONFLICTS YATH
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

use Test2::Harness2::Util::JSON qw/decode_json/;
use App::Yath2::Log;

# Build a small passing run, then archive it under three shapes
# (extracted directory, tar.zidx, and sqlite). Verify `yath inspect`
# correctly identifies and validates each, and rejects an unrelated
# file.

my $tmp = tempdir(CLEANUP => 1);
my $tdir = "$tmp/tests";
make_path($tdir);

open(my $tf, '>', "$tdir/x.tx") or die $!;
print $tf "use Test2::V0;\nok(1, 'good');\ndone_testing;\n";
close $tf;

my $tar_archive = "$tmp/run.yath";

yath(
    command => 'test',
    args    => [
        $tdir,
        '--ext=tx',
        "--log-file=$tar_archive",
    ],
    exit    => 0,
);

ok(-f $tar_archive, 'tar.zidx archive created');

# Extract the archive to a directory so we can inspect-as-directory.
my $logs_dir = "$tmp/extracted";
yath(
    command => 'extract',
    args    => [$tar_archive, $logs_dir],
    exit    => 0,
);
ok(-d $logs_dir, 'extracted directory exists');

# {{{ Tar.zidx archive
yath(
    command => 'inspect',
    args    => [$tar_archive],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^Path:\s+\Q$tar_archive\E/m, 'Path line');
        like($out->{output}, qr/^Type:\s+tar\.zidx/m, 'Type tar.zidx');
        like($out->{output}, qr/^Valid:\s+yes/m, 'Valid yes');
        like($out->{output}, qr{^Harness:\s+services/harness/spec\.jsonl\.zst}m, 'harness line');
        like($out->{output}, qr/^Runs:\s+\d+/m, 'Runs line');
        like($out->{output}, qr/^Globals:\s+\d+/m, 'Globals line');
        # meta.json fields
        like($out->{output}, qr/^Archive UUID:\s+[0-9A-Fa-f-]{36}/m,
            'Archive UUID line');
        like($out->{output}, qr/^Created at:\s+\d{4}-\d{2}-\d{2}T/m,
            'Created at ISO line');
        like($out->{output}, qr/^Host:\s+\S+/m,         'Host line');
        like($out->{output}, qr/^Yath version:\s+\S+/m, 'Yath version line');
    },
);
# }}}

# {{{ Tar.zidx archive --json
yath(
    command => 'inspect',
    args    => ['--json', $tar_archive],
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $json = $out->{output};
        my $rep;
        my $ok = eval { $rep = decode_json($json); 1 };
        ok($ok, 'inspect --json emitted parseable JSON') or diag($json);
        is($rep->{type},  'tar.zidx', 'json type');
        is($rep->{valid}, 1,          'json valid');
        is($rep->{harness}{ok}, 1, 'json harness ok');
        ok(ref($rep->{runs}) eq 'ARRAY', 'json runs is an array');
        ok(ref($rep->{globals}) eq 'ARRAY', 'json globals is an array');
        ok(ref($rep->{meta}) eq 'HASH', 'json meta is a hashref');
        is($rep->{meta}{format_version}, 1, 'json meta format_version');
        like($rep->{meta}{archive_uuid}, qr/^[0-9A-Fa-f-]{36}$/, 'json meta archive_uuid');
        like($rep->{meta}{created_at},   qr/^\d{4}-\d{2}-\d{2}T/, 'json meta created_at');
    },
);
# }}}

# {{{ Directory log
yath(
    command => 'inspect',
    args    => [$logs_dir],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^Type:\s+directory/m, 'Type directory');
        like($out->{output}, qr/^Valid:\s+yes/m, 'Valid yes');
        like($out->{output}, qr{^Harness:\s+services/harness/spec\.jsonl\.zst}m, 'directory harness line');
    },
);
# }}}

# {{{ Single-archive sqlite
my $sqlite_single = "$tmp/single.yath";
{
    my $log = App::Yath2::Log->new(dir => $logs_dir);
    $log->archive($sqlite_single, format => 'sqlite');
}
ok(-f $sqlite_single, 'sqlite single-archive file written');

yath(
    command => 'inspect',
    args    => [$sqlite_single],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^Type:\s+sqlite/m, 'Type sqlite');
        like($out->{output}, qr/^Valid:\s+yes/m, 'Valid yes');
        # Single-archive sealed sqlite: meta block from YATHFOOT replaces
        # the redundant "Archives: 1 / - <uuid>" list.
        like($out->{output}, qr/^Archive UUID:\s+\S+/m, 'Archive UUID line from meta');
        like($out->{output}, qr/^Yath version:\s+\S+/m, 'Yath version line from meta');
        like($out->{output}, qr/^Runs:\s+/m, 'Runs summary printed');
    },
);
# }}}

# {{{ Multi-archive sqlite — insert the same source three times
# (D6: archive_uuid carries over from the source, so a vanilla
# re-insert would now refuse as a duplicate. Use explicit override
# uuids to land three distinct archive rows.)
my $sqlite_multi = "$tmp/multi.yath";
{
    require App::Yath2::DB;
    require Test2::Util::UUID;
    Test2::Util::UUID->import('gen_uuid');
    my $dest = App::Yath2::DB->open(file => $sqlite_multi);
    my $src  = App::Yath2::Log->new(dir => $logs_dir);
    $dest->insert($src, archive_uuid => gen_uuid());
    $dest->insert($src, archive_uuid => gen_uuid());
    $dest->insert($src, archive_uuid => gen_uuid());
}

yath(
    command => 'inspect',
    args    => [$sqlite_multi],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^Type:\s+sqlite/m, 'Type sqlite (multi)');
        like($out->{output}, qr/^Valid:\s+yes/m, 'Valid yes (multi)');
        like($out->{output}, qr/^Archives:\s+3/m, 'Archives: 3 line');
        my @archive_lines = ($out->{output} =~ m/^\s*-\s+\S+\s+\(\d+ runs?\)$/mg);
        is(scalar @archive_lines, 3, 'three archive lines printed');
    },
);

yath(
    command => 'inspect',
    args    => ['--json', $sqlite_multi],
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $rep;
        my $ok = eval { $rep = decode_json($out->{output}); 1 };
        ok($ok, 'multi-archive inspect --json parses') or diag($out->{output});
        is($rep->{type},  'sqlite', 'json type sqlite');
        is($rep->{valid}, 1,        'json valid');
        is($rep->{archive_count}, 3, 'json archive_count');
        ok(ref($rep->{archives}) eq 'ARRAY', 'json archives is array');
        is(scalar @{$rep->{archives}}, 3, 'three archive entries');
    },
);
# }}}

# {{{ Invalid file (no magic bytes)
my $bogus = "$tmp/bogus.yath";
{
    open(my $fh, '>', $bogus) or die $!;
    print $fh "this is not a yath archive\n";
    close $fh;
}

yath(
    command => 'inspect',
    args    => [$bogus],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^Valid:\s+no/m, 'invalid file -> Valid: no');
        like($out->{output}, qr/Error:.*magic|not a yath/m, 'error mentions magic / not a yath');
    },
);
# }}}

# {{{ Missing path is rejected
{
    my $missing = "$tmp/nope.yath";
    yath(
        command => 'inspect',
        args    => [$missing],
        exit    => T(),
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/does not exist/, 'inspect errors on missing path');
        },
    );
}
# }}}

done_testing;

use Test2::V0;
use File::Temp qw/tempdir tempfile/;
use File::Spec;

use Test2::Harness2::Util qw{
    apply_encoding
    clean_path
    close_file
    fqmod
    hub_truth
    load_module
    lock_file
    looks_like_uuid
    maybe_open_file
    maybe_read_file
    mod2file
    open_file
    parse_exit
    read_file
    unlock_file
    write_file
    write_file_atomic
    write_file_atomic_mode
};

subtest mod2file => sub {
    is(mod2file('Foo::Bar'),       'Foo/Bar.pm');
    is(mod2file('Foo::Bar::Baz'),  'Foo/Bar/Baz.pm');
    is(mod2file('Foo'),            'Foo.pm');
    like(dies { mod2file(undef) }, qr/No module name provided/);
};

subtest parse_exit => sub {
    is(parse_exit(0),   {sig => 0, err => 0,   dmp => 0,   all => 0});
    is(parse_exit(256), {sig => 0, err => 1,   dmp => 0,   all => 256});
    is(parse_exit(15),  {sig => 15, err => 0,  dmp => 0,   all => 15});
    is(parse_exit(143), {sig => 15, err => 0,  dmp => 128, all => 143});
    like(dies { parse_exit(undef) }, qr/exit value is required/);
};

subtest hub_truth => sub {
    is(hub_truth({}),                               {});
    is(hub_truth({trace => {pid => 1}}),            {pid => 1});
    is(hub_truth({hubs => [{a => 1}, {a => 2}]}),   {a => 1});
    is(hub_truth({hubs => [], trace => {x => 1}}),  {x => 1});
};

subtest apply_encoding => sub {
    my ($fh) = tempfile(UNLINK => 1);
    ok(lives { apply_encoding($fh, undef) },  'undef is a no-op');
    ok(lives { apply_encoding($fh, 'utf8') }, 'utf8 OK');
    ok(lives { apply_encoding($fh, 'UTF-8') }, 'UTF-8 OK');
};

subtest clean_path => sub {
    my $abs = clean_path('.');
    ok(File::Spec->file_name_is_absolute($abs), 'clean_path returns absolute');
    like(dies { clean_path('') }, qr/No path/);
};

subtest write_and_read_file => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x.txt";
    write_file($f, "hello\n", "world\n");
    is(read_file($f), "hello\nworld\n");
    is(maybe_read_file("$dir/missing"), undef);
};

subtest write_file_atomic => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/atomic.txt";
    write_file_atomic($f, "data\n");
    is(read_file($f), "data\n");
    ok(!-e "$f.pend", 'pend cleaned up');
};

subtest write_file_atomic_mode => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/mode.txt";
    write_file_atomic_mode($f, 0600, "secret\n");
    is(read_file($f), "secret\n");
    my $mode = (stat($f))[2] & 07777;
    is($mode, 0600, 'mode 0600 applied');
};

subtest open_close_file => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/oc.txt";
    write_file($f, "hi\n");
    my $fh = open_file($f);
    ok($fh, 'got handle');
    close_file($fh, $f);
    ok(!defined maybe_open_file("$dir/missing"), 'maybe_open_file returns undef on missing');
};

subtest load_module => sub {
    is(load_module('Test2::Harness2::Util'), 'Test2::Harness2::Util');
    like(dies { load_module(undef) }, qr/required/);
};

subtest fqmod => sub {
    is(fqmod('Util', 'Test2::Harness2', no_require => 1), 'Test2::Harness2::Util');
    is(fqmod('+Test2::Harness2::Util', 'Test2::Harness2'), 'Test2::Harness2::Util');
    like(dies { fqmod('Util', 'NonExistent::Prefix') }, qr/Could not locate/);
};

subtest looks_like_uuid => sub {
    ok(looks_like_uuid('019E426A-3BCA-795B-A0A7-CA1787BCBBE3'));
    ok(!looks_like_uuid('not-a-uuid'));
};

subtest lock_unlock => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/lockfile";
    write_file($f, '');
    my $fh = lock_file($f);
    ok($fh, 'got lock fh');
    ok(unlock_file($fh), 'unlock OK');
    close($fh);
};

done_testing;

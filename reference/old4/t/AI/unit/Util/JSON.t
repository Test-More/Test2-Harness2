use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::JSON qw{
    decode_json
    decode_json_file
    decode_json_no_null
    decode_json_zst_file
    encode_json
    encode_json_file
    encode_pretty_json
    json_false
    json_true
    write_json_file_atomic
    write_json_zst_file_atomic
};

subtest round_trip => sub {
    my $data = {a => 1, b => [1, 2, 3], c => {x => "y"}};
    my $j    = encode_json($data);
    is(decode_json($j), $data);
};

subtest pretty => sub {
    my $j = encode_pretty_json({b => 1, a => 2});
    like($j, qr/"a"\s*:\s*2/, 'pretty + canonical');
    like($j, qr/\n/, 'has newlines');
};

subtest bool => sub {
    my $j = encode_json({t => json_true(), f => json_false()});
    like($j, qr/"t":true/);
    like($j, qr/"f":false/);
};

subtest no_null => sub {
    my $raw = qq[{"x":"a\\u0000b"}];
    my $d = decode_json_no_null($raw);
    is($d->{x}, "a\\u0000b", 'escaped null preserved');
};

subtest file_round_trip => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $tmp = encode_json_file({k => "v"});
    is(decode_json_file($tmp, unlink => 1), {k => "v"});
    ok(!-e $tmp, 'unlink removed it');
};

subtest atomic_json => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x.json";
    write_json_file_atomic($f, {a => 1});
    is(decode_json_file($f), {a => 1});
};

subtest atomic_zst_json => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $f   = "$dir/x.json.zst";
    write_json_zst_file_atomic($f, {a => 1});
    is(decode_json_zst_file($f), {a => 1});
};

done_testing;

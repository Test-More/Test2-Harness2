use Test2::V0;

use Test2::Harness2::Util::JSON qw/
    encode_json
    decode_json
    encode_pretty_json
    json_true
    json_false
/;

subtest 'encode/decode roundtrip' => sub {
    my $data    = {foo => 'bar', num => 42, list => [1, 2, 3]};
    my $encoded = encode_json($data);
    my $decoded = decode_json($encoded);
    is($decoded, $data, "roundtrip preserves data structure");
};

subtest 'encode_json produces ASCII-safe output' => sub {
    my $data    = {key => "caf\x{e9}"};
    my $encoded = encode_json($data);
    ok($encoded !~ /[^\x00-\x7f]/, "encoded output is ASCII-only");
    my $decoded = decode_json($encoded);
    is($decoded->{key}, "caf\x{e9}", "Unicode roundtrip works");
};

subtest 'encode_pretty_json' => sub {
    my $data   = {a => 1, b => 2};
    my $pretty = encode_pretty_json($data);
    ok($pretty =~ /\n/, "pretty output has newlines");
    my $decoded = decode_json($pretty);
    is($decoded, $data, "pretty JSON roundtrips correctly");
};

subtest 'json_true and json_false' => sub {
    my $t = json_true();
    my $f = json_false();
    ok($t,  "json_true is truthy");
    ok(!$f, "json_false is falsy");

    my $encoded = encode_json({t => $t, f => $f});
    my $decoded = decode_json($encoded);
    ok($decoded->{t},  "true roundtrips as truthy");
    ok(!$decoded->{f}, "false roundtrips as falsy");

    like($encoded, qr/"t"\s*:\s*true/,  "true encodes as JSON true");
    like($encoded, qr/"f"\s*:\s*false/, "false encodes as JSON false");
};

subtest 'blessed object encoding' => sub {

    package My::Obj;
    sub new     { bless {val => $_[1]}, $_[0] }
    sub TO_JSON { {val => $_[0]->{val}} }

    package main;
    my $obj     = My::Obj->new(42);
    my $encoded = encode_json($obj);
    my $decoded = decode_json($encoded);
    is($decoded->{val}, 42, "blessed object encoded via TO_JSON");
};

subtest 'decode_json handles arrays at top level' => sub {
    my $data    = [1, 2, 3];
    my $encoded = encode_json($data);
    my $decoded = decode_json($encoded);
    is($decoded, $data, "array roundtrip works");
};

subtest 'decode_json handles scalar at top level' => sub {
    my $encoded = encode_json(42);
    my $decoded = decode_json($encoded);
    is($decoded, 42, "scalar roundtrip works");
};

done_testing;

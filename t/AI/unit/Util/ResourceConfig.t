use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempfile tempdir/;

use Test2::Harness2::Util::ResourceConfig qw{
    slurp_json_config
    whitelist_keys
    validate_name
};

my $tmp = tempdir(CLEANUP => 1);

sub write_file {
    my ($name, $body) = @_;
    my $path = "$tmp/$name";
    open my $fh, '>:raw', $path or die "open '$path': $!";
    print {$fh} $body;
    close $fh;
    return $path;
}

# ----------------------------------------------------------------------
subtest 'slurp_json_config: happy path' => sub {
    my $p = write_file('ok.json', qq[{"a":1,"b":"two"}\n]);
    my $data = slurp_json_config($p, 'Resource::Test');
    is($data, {a => 1, b => 'two'}, 'decoded correctly');
};

subtest 'slurp_json_config: missing file' => sub {
    like(
        dies { slurp_json_config("$tmp/no-such-file.json", 'Resource::Test') },
        qr/Resource::Test config file .*no-such-file\.json' does not exist/,
        'missing file error includes label and path'
    );
};

subtest 'slurp_json_config: unreadable file' => sub {
    my $p = write_file('unreadable.json', qq[{"a":1}]);
    chmod 0000, $p or skip_all "cannot chmod 0 on this fs";
    my $is_root = ($> == 0);
    if ($is_root) {
        chmod 0644, $p;
        skip_all "running as root: -r always true";
    }
    like(
        dies { slurp_json_config($p, 'Resource::Test') },
        qr/Resource::Test config file '.*unreadable\.json' is not readable/,
        'unreadable file error'
    );
    chmod 0644, $p;
};

subtest 'slurp_json_config: bad JSON' => sub {
    my $p = write_file('bad.json', "{not json");
    like(
        dies { slurp_json_config($p, 'Resource::Test') },
        qr/Resource::Test: cannot parse JSON in '.*bad\.json'/,
        'JSON parse error includes label and path'
    );
};

subtest 'slurp_json_config: non-object top level' => sub {
    my $p = write_file('array.json', "[1,2,3]");
    like(
        dies { slurp_json_config($p, 'Resource::Test') },
        qr/Resource::Test: top-level of '.*array\.json' must be a JSON object/,
        'non-object top level rejected'
    );
};

subtest 'slurp_json_config: required args' => sub {
    like(
        dies { slurp_json_config(undef, 'Resource::Test') },
        qr/'path' is required/,
        'path required'
    );
    like(
        dies { slurp_json_config("$tmp/x", undef) },
        qr/'label' is required/,
        'label required'
    );
};

# ----------------------------------------------------------------------
subtest 'whitelist_keys: arrayref allowed' => sub {
    ok(lives { whitelist_keys({a => 1, b => 2}, [qw/a b c/], '/tmp/x', 'L') }, 'all allowed');

    like(
        dies { whitelist_keys({a => 1, z => 2}, [qw/a b/], '/tmp/x', 'L') },
        qr/L: unknown key 'z' in '\/tmp\/x'/,
        'unknown key reported with label and path'
    );
};

subtest 'whitelist_keys: hashref allowed' => sub {
    my %allow = (a => 1, b => 1);
    ok(lives { whitelist_keys({a => 1}, \%allow, '/tmp/x', 'L') }, 'hash allow set ok');
    like(
        dies { whitelist_keys({nope => 1}, \%allow, '/tmp/x', 'L') },
        qr/L: unknown key 'nope' in '\/tmp\/x'/,
        'hash allow rejects unknown'
    );
};

subtest 'whitelist_keys: deterministic order' => sub {
    like(
        dies { whitelist_keys({zeta => 1, alpha => 2}, ['ok'], '/tmp/x', 'L') },
        qr/'alpha'/,
        'first key reported is alphabetically first'
    );
};

subtest 'whitelist_keys: arg type errors' => sub {
    like(
        dies { whitelist_keys([], [], '/tmp/x', 'L') },
        qr/'data' must be a HASH ref/,
        'data type check'
    );
    like(
        dies { whitelist_keys({}, 'oops', '/tmp/x', 'L') },
        qr/'allowed' must be ARRAY or HASH ref/,
        'allowed type check'
    );
};

# ----------------------------------------------------------------------
subtest 'validate_name: accepts good names' => sub {
    is(validate_name('cpu',       'L'), 'cpu',       'simple');
    is(validate_name('my-name_1', 'L'), 'my-name_1', 'hyphen/underscore/digit ok');
};

subtest 'validate_name: rejects bad names' => sub {
    like(dies { validate_name(undef, 'L') }, qr/L: name must be a non-empty whitespace-free string/, 'undef');
    like(dies { validate_name('',    'L') }, qr/L: name must be a non-empty whitespace-free string/, 'empty');
    like(dies { validate_name('a b', 'L') }, qr/L: name must be a non-empty whitespace-free string/, 'space');
    like(dies { validate_name("a\t", 'L') }, qr/L: name must be a non-empty whitespace-free string/, 'tab');
    like(dies { validate_name({},    'L') }, qr/L: name must be a non-empty whitespace-free string/, 'ref');
};

subtest 'validate_name: where suffix in error' => sub {
    like(
        dies { validate_name('', 'L', " in '/tmp/x'") },
        qr{L: name in '/tmp/x' must be a non-empty whitespace-free string},
        'where suffix included'
    );
};

subtest 'validate_name: label required' => sub {
    like(
        dies { validate_name('ok', undef) },
        qr/'label' is required/,
        'label required'
    );
};

done_testing;

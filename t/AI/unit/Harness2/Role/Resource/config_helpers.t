use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempfile tempdir/;

# Exercise the option-parsing helpers (slurp_json_config,
# whitelist_keys, validate_name, label) that Test2::Harness2::Role::Resource
# provides for its consumers. The methods are called via a real
# consumer (Test2::Harness2::Resource::CPU) so the label-derivation
# logic gets exercised end to end.
use Test2::Harness2::Resource::CPU;
use Test2::Harness2::Role::Resource;

my $CPU  = 'Test2::Harness2::Resource::CPU';
my $ROLE = 'Test2::Harness2::Role::Resource';

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
subtest 'label derives from consumer class' => sub {
    is($CPU->label,  'Resource::CPU', 'consumer-side label');
    is($ROLE->label, 'Role::Resource', 'role-side label (called directly on role)');
};

# ----------------------------------------------------------------------
subtest 'slurp_json_config: happy path' => sub {
    my $p = write_file('ok.json', qq[{"a":1,"b":"two"}\n]);
    my $data = $CPU->slurp_json_config($p);
    is($data, {a => 1, b => 'two'}, 'decoded correctly');
};

subtest 'slurp_json_config: missing file' => sub {
    like(
        dies { $CPU->slurp_json_config("$tmp/no-such-file.json") },
        qr/Resource::CPU config file .*no-such-file\.json' does not exist/,
        'missing file error includes label and path'
    );
};

subtest 'slurp_json_config: unreadable file' => sub {
    my $p = write_file('unreadable.json', qq[{"a":1}]);
    chmod 0000, $p or skip_all "cannot chmod 0 on this fs";
    if ($> == 0) {
        chmod 0644, $p;
        skip_all "running as root: -r always true";
    }
    like(
        dies { $CPU->slurp_json_config($p) },
        qr/Resource::CPU config file '.*unreadable\.json' is not readable/,
        'unreadable file error'
    );
    chmod 0644, $p;
};

subtest 'slurp_json_config: bad JSON' => sub {
    my $p = write_file('bad.json', "{not json");
    like(
        dies { $CPU->slurp_json_config($p) },
        qr/Resource::CPU: cannot parse JSON in '.*bad\.json'/,
        'JSON parse error includes label and path'
    );
};

subtest 'slurp_json_config: non-object top level' => sub {
    my $p = write_file('array.json', "[1,2,3]");
    like(
        dies { $CPU->slurp_json_config($p) },
        qr/Resource::CPU: top-level of '.*array\.json' must be a JSON object/,
        'non-object top level rejected'
    );
};

subtest 'slurp_json_config: required args' => sub {
    like(
        dies { $CPU->slurp_json_config(undef) },
        qr/'path' is required/,
        'path required'
    );
};

# ----------------------------------------------------------------------
subtest 'whitelist_keys: arrayref allowed' => sub {
    ok(lives { $CPU->whitelist_keys({a => 1, b => 2}, [qw/a b c/], '/tmp/x') }, 'all allowed');

    like(
        dies { $CPU->whitelist_keys({a => 1, z => 2}, [qw/a b/], '/tmp/x') },
        qr/Resource::CPU: unknown key 'z' in '\/tmp\/x'/,
        'unknown key reported with label and path'
    );
};

subtest 'whitelist_keys: hashref allowed' => sub {
    my %allow = (a => 1, b => 1);
    ok(lives { $CPU->whitelist_keys({a => 1}, \%allow, '/tmp/x') }, 'hash allow set ok');
    like(
        dies { $CPU->whitelist_keys({nope => 1}, \%allow, '/tmp/x') },
        qr/Resource::CPU: unknown key 'nope' in '\/tmp\/x'/,
        'hash allow rejects unknown'
    );
};

subtest 'whitelist_keys: deterministic order' => sub {
    like(
        dies { $CPU->whitelist_keys({zeta => 1, alpha => 2}, ['ok'], '/tmp/x') },
        qr/'alpha'/,
        'first key reported is alphabetically first'
    );
};

subtest 'whitelist_keys: arg type errors' => sub {
    like(
        dies { $CPU->whitelist_keys([], [], '/tmp/x') },
        qr/'data' must be a HASH ref/,
        'data type check'
    );
    like(
        dies { $CPU->whitelist_keys({}, 'oops', '/tmp/x') },
        qr/'allowed' must be ARRAY or HASH ref/,
        'allowed type check'
    );
};

# ----------------------------------------------------------------------
subtest 'validate_name: accepts good names' => sub {
    is($CPU->validate_name('cpu'),       'cpu',       'simple');
    is($CPU->validate_name('my-name_1'), 'my-name_1', 'hyphen/underscore/digit ok');
};

subtest 'validate_name: rejects bad names' => sub {
    like(dies { $CPU->validate_name(undef) }, qr/Resource::CPU: name must be a non-empty whitespace-free string/, 'undef');
    like(dies { $CPU->validate_name('')    }, qr/Resource::CPU: name must be a non-empty whitespace-free string/, 'empty');
    like(dies { $CPU->validate_name('a b') }, qr/Resource::CPU: name must be a non-empty whitespace-free string/, 'space');
    like(dies { $CPU->validate_name("a\t") }, qr/Resource::CPU: name must be a non-empty whitespace-free string/, 'tab');
    like(dies { $CPU->validate_name({})    }, qr/Resource::CPU: name must be a non-empty whitespace-free string/, 'ref');
};

subtest 'validate_name: where suffix in error' => sub {
    like(
        dies { $CPU->validate_name('', " in '/tmp/x'") },
        qr{Resource::CPU: name in '/tmp/x' must be a non-empty whitespace-free string},
        'where suffix included'
    );
};

done_testing;

use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Resource::Throttle;

sub kvhash { my %h = @_; \%h }

subtest 'inline single rule' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('5/2s'));
    is($args->{cap},    5,          'cap');
    is($args->{window}, 2,          'window seconds');
    is($args->{name},   'throttle', 'default name');
};

subtest 'sub-second window' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('10/500ms'));
    is($args->{cap},    10,  'cap');
    is($args->{window}, 0.5, 'window 500ms = 0.5s');
};

subtest 'minute window' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('3/1m'));
    is($args->{cap},    3,  'cap');
    is($args->{window}, 60, 'window 1m = 60s');
};

subtest 'bare-number window defaults to seconds' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('5/2'));
    is($args->{window}, 2, 'window 2 = 2s');
};

subtest 'bare-cap shorthand defaults to /1s' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('5'));
    is($args->{cap},    5, 'cap');
    is($args->{window}, 1, 'window defaults to 1s');

    my $args2 = kvhash(Test2::Harness2::Resource::Throttle->parse_options('20'));
    is($args2->{cap},    20, 'cap=20');
    is($args2->{window}, 1,  'window defaults to 1s');

    # Equivalence: bare-cap should produce the same ctor args as the
    # explicit /1s form.
    my $a = kvhash(Test2::Harness2::Resource::Throttle->parse_options('7'));
    my $b = kvhash(Test2::Harness2::Resource::Throttle->parse_options('7/1s'));
    is($a, $b, 'bare-cap == explicit /1s');
};

subtest 'name= entry' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::Throttle->parse_options('5/2s', 'name=db_throttle'),
    );
    is($args->{name}, 'db_throttle', 'custom name');
};

subtest 'name= works with bare-cap shorthand' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::Throttle->parse_options('5', 'name=quick'),
    );
    is($args->{cap},    5,       'cap');
    is($args->{window}, 1,       'default window');
    is($args->{name},   'quick', 'name parsed alongside shorthand');
};

subtest 'config file via @path' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{
  "cap":    7,
  "window": "1500ms",
  "name":   "from_file"
}
JSON
    close $fh;

    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('@' . $path));
    is($args->{cap},    7,           'cap from file');
    is($args->{window}, 1.5,         'window from file');
    is($args->{name},   'from_file', 'name from file');
};

subtest 'inline overrides file (later wins per key)' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "cap": 7, "window": "1s", "name": "from_file" }
JSON
    close $fh;

    my $args = kvhash(
        Test2::Harness2::Resource::Throttle->parse_options(
            '@' . $path,
            '5/2s',
            'name=inline',
        ),
    );
    is($args->{cap},    5,        'inline cap wins');
    is($args->{window}, 2,        'inline window wins');
    is($args->{name},   'inline', 'inline name wins');
};

subtest 'bare-cap shorthand overrides file' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "cap": 7, "window": "5s" }
JSON
    close $fh;

    my $args = kvhash(
        Test2::Harness2::Resource::Throttle->parse_options('@' . $path, '3'),
    );
    is($args->{cap},    3, 'inline bare cap wins');
    is($args->{window}, 1, 'shorthand resets window to 1s');
};

subtest 'resource-group key/value pairs are dropped' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::Throttle->parse_options(
            slots       => 4,
            job_slots   => 1,
            classes     => {},
            utilize     => 80,
            no_resource => 0,
            '5/2s',
        ),
    );
    ok(!exists $args->{slots},   'slots dropped');
    ok(!exists $args->{utilize}, 'utilize dropped');
    is($args->{cap}, 5, 'rule still parsed');
};

subtest 'invalid entry croaks with offender named' => sub {
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('not-a-rule') },
        qr/not-a-rule/, 'bare junk named'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('0/2s') },
        qr/0/, 'cap=0 rejected (explicit form)'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('0') },
        qr/0/, 'cap=0 rejected (bare shorthand)'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('5/abc') },
        qr/abc/, 'bad duration named'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('@/no/such/file') },
        qr{/no/such/file}, 'missing config file'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('5/2s', 'name=') },
        qr/name=/, 'empty name= rejected'
    );
};

subtest 'unknown config keys croak' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "cup": 5, "window": "2s" }
JSON
    close $fh;

    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('@' . $path) },
        qr/cup/, 'top-level typo'
    );
};

subtest 'config file requires cap and window' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "cap": 5 }
JSON
    close $fh;

    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('@' . $path) },
        qr/window/, 'missing window'
    );

    my ($fh2, $path2) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh2} <<'JSON';
{ "window": "2s" }
JSON
    close $fh2;

    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('@' . $path2) },
        qr/cap/, 'missing cap'
    );
};

subtest 'multiple inline rules rejected' => sub {
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('5/2s', '10/30s') },
        qr/single rule/, 'two rules in one instance is an error'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('5', '10') },
        qr/single rule/, 'two bare-cap entries is also an error'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('5', '10/2s') },
        qr/single rule/, 'mixed bare-cap and explicit is also an error'
    );
};

subtest 'new grammar: 1/core/1s' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('1/core/1s'));
    is($args->{cap},    1, 'cap');
    is($args->{window}, 1, 'window 1s');
    ok(exists $args->{bases}, 'bases present');
    my $bases = $args->{bases};
    is(scalar @$bases,    1,      'one basis');
    is($bases->[0]{type}, 'core', 'basis type is core');
};

subtest 'new grammar: 1/cores/1s (plural)' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('1/cores/1s'));
    is($args->{bases}[0]{type}, 'core', 'cores plural accepted as core');
};

subtest 'new grammar: 1/1gb/1s (single RAM basis)' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('1/1gb/1s'));
    is($args->{cap},    1, 'cap');
    is($args->{window}, 1, 'window 1s');
    my $bases = $args->{bases};
    is(scalar @$bases,     1,                  'one basis');
    is($bases->[0]{type},  'ram',              'basis type is ram');
    is($bases->[0]{bytes}, 1024 * 1024 * 1024, '1gb in bytes');
};

subtest 'new grammar: 1/core,100mb/1s (two bases)' => sub {
    my $args  = kvhash(Test2::Harness2::Resource::Throttle->parse_options('1/core,100mb/1s'));
    my $bases = $args->{bases};
    is(scalar @$bases,     2,                 'two bases');
    is($bases->[0]{type},  'core',            'first basis: core');
    is($bases->[1]{type},  'ram',             'second basis: ram');
    is($bases->[1]{bytes}, 100 * 1024 * 1024, '100mb in bytes');
};

subtest 'new grammar: 1/core,500mb,1gb/2s (three bases)' => sub {
    my $args  = kvhash(Test2::Harness2::Resource::Throttle->parse_options('1/core,500mb,1gb/2s'));
    my $bases = $args->{bases};
    is(scalar @$bases,     3,                  'three bases');
    is($bases->[0]{type},  'core',             'first: core');
    is($bases->[1]{type},  'ram',              'second: ram 500mb');
    is($bases->[1]{bytes}, 500 * 1024 * 1024,  '500mb in bytes');
    is($bases->[2]{type},  'ram',              'third: ram 1gb');
    is($bases->[2]{bytes}, 1024 * 1024 * 1024, '1gb in bytes');
    is($args->{window},    2,                  'window 2s');
};

subtest 'new grammar: backward-compat 5/2s still works' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('5/2s'));
    is($args->{cap},    5, 'cap');
    is($args->{window}, 2, 'window');
    ok(!exists $args->{bases} || !@{$args->{bases} // []}, 'no bases set');
};

subtest 'new grammar: bare cap shorthand still works' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Throttle->parse_options('5'));
    is($args->{cap},    5, 'cap');
    is($args->{window}, 1, 'window 1s');
    ok(!exists $args->{bases} || !@{$args->{bases} // []}, 'no bases set');
};

subtest 'new grammar: invalid - empty basis segment (1//1s)' => sub {
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('1//1s') },
        qr/window|duration|bad/, 'empty basis (two slashes) caught - treated as bad window'
    );
};

subtest 'new grammar: invalid - unknown unit (1/foo/1s)' => sub {
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('1/foo/1s') },
        qr/foo/, 'unknown basis unit named'
    );
};

subtest 'new grammar: invalid - negative cap (0/core/1s)' => sub {
    like(
        dies { Test2::Harness2::Resource::Throttle->parse_options('0/core/1s') },
        qr/cap/, 'zero cap rejected in three-segment form'
    );
};

done_testing;

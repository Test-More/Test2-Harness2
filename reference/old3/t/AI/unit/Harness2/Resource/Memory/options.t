use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Resource::Memory;

sub kvhash { my %h = @_; \%h }

subtest 'no args -> default min_free=5%' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Memory->parse_options());
    is($args->{min_free}, {kind => 'pct', value => 5}, 'default');
    is($args->{name},     'memory',                    'default name');
};

subtest 'inline pct' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Memory->parse_options('20%'));
    is($args->{min_free}, {kind => 'pct', value => 20}, '20%');
};

subtest 'inline bytes' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Memory->parse_options('512mb'));
    is($args->{min_free}, {kind => 'bytes', value => 512 * 1024**2}, '512mb');
};

subtest 'min_free explicit key' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::Memory->parse_options('min_free=1gb'),
    );
    is($args->{min_free}, {kind => 'bytes', value => 1024**3}, '1gb');
};

subtest 'name= entry' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::Memory->parse_options('20%', 'name=ram'),
    );
    is($args->{name}, 'ram', 'custom name');
};

subtest 'config file via @path' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "min_free": "30%", "name": "from_file" }
JSON
    close $fh;
    my $args = kvhash(Test2::Harness2::Resource::Memory->parse_options('@' . $path));
    is($args->{min_free}, {kind => 'pct', value => 30}, 'min_free from file');
    is($args->{name},     'from_file',                  'name from file');
};

subtest 'inline overrides file' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "min_free": "10%" }
JSON
    close $fh;
    my $args = kvhash(
        Test2::Harness2::Resource::Memory->parse_options('@' . $path, '50%'),
    );
    is($args->{min_free}, {kind => 'pct', value => 50}, 'inline wins');
};

subtest 'resource-group noise dropped' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::Memory->parse_options(
            slots       => 4,
            classes     => {},
            utilize     => 80,
            no_resource => 0,
            '15%',
        ),
    );
    ok(!exists $args->{slots},   'slots dropped');
    ok(!exists $args->{utilize}, 'utilize dropped');
    is($args->{min_free}, {kind => 'pct', value => 15}, 'rule still parsed');
};

subtest 'invalid entries croak' => sub {
    like(
        dies { Test2::Harness2::Resource::Memory->parse_options('abc') },
        qr/abc/, 'bad threshold'
    );
    like(
        dies { Test2::Harness2::Resource::Memory->parse_options('@/no/such/file') },
        qr{/no/such/file}, 'missing config'
    );
};

done_testing;

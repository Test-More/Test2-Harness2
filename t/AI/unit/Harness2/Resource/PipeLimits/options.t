use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Resource::PipeLimits;

sub kvhash { my %h = @_; \%h }

subtest 'no args -> defaults' => sub {
    my $args = kvhash(Test2::Harness2::Resource::PipeLimits->parse_options());
    is($args->{pipes_per_test},    2,                            'pipes_per_test default');
    is($args->{pipes_per_service}, 2,                            'pipes_per_service default');
    is($args->{service_count},     0,                            'service_count default');
    is($args->{headroom},          {kind => 'pct', value => 10}, 'headroom default');
    is($args->{name},              'pipelimits',                 'default name');
};

subtest 'bare = headroom pct' => sub {
    my $args = kvhash(Test2::Harness2::Resource::PipeLimits->parse_options('20%'));
    is($args->{headroom}, {kind => 'pct', value => 20}, '20%');
};

subtest 'bare = headroom count' => sub {
    my $args = kvhash(Test2::Harness2::Resource::PipeLimits->parse_options('64'));
    is($args->{headroom}, {kind => 'count', value => 64}, '64 pages');
};

subtest 'mixed knobs' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::PipeLimits->parse_options(
            'service_count=5', 'pipes_per_test=4', 'headroom=15%',
        ),
    );
    is($args->{service_count},  5,                            'service_count');
    is($args->{pipes_per_test}, 4,                            'pipes_per_test');
    is($args->{headroom},       {kind => 'pct', value => 15}, 'headroom');
};

subtest 'config file' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{
  "service_count": 3,
  "pipes_per_test": 4,
  "pipes_per_service": 2,
  "headroom": "20%",
  "name": "pipes"
}
JSON
    close $fh;
    my $args = kvhash(Test2::Harness2::Resource::PipeLimits->parse_options('@' . $path));
    is($args->{service_count},     3,                            'from file');
    is($args->{pipes_per_test},    4,                            'from file');
    is($args->{pipes_per_service}, 2,                            'from file');
    is($args->{headroom},          {kind => 'pct', value => 20}, 'from file');
    is($args->{name},              'pipes',                      'name from file');
};

subtest 'invalid' => sub {
    like(
        dies { Test2::Harness2::Resource::PipeLimits->parse_options('pipes_per_test=-1') },
        qr/pipes_per_test/, 'negative'
    );
    like(
        dies { Test2::Harness2::Resource::PipeLimits->parse_options('headroom=0%') },
        qr/headroom/, 'zero pct'
    );
};

done_testing;

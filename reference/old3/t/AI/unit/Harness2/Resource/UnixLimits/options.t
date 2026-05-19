use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Resource::UnixLimits;

sub kvhash { my %h = @_; \%h }

subtest 'no args -> defaults (nproc=10%, nofile=10%, as off)' => sub {
    my $args = kvhash(Test2::Harness2::Resource::UnixLimits->parse_options());
    is($args->{nproc},  {kind => 'pct', value => 10}, 'nproc default');
    is($args->{nofile}, {kind => 'pct', value => 10}, 'nofile default');
    ok(!exists $args->{as}, 'as off by default');
    is($args->{name}, 'unixlimits', 'default name');
};

subtest 'bare % applied to nproc + nofile (not as)' => sub {
    my $args = kvhash(Test2::Harness2::Resource::UnixLimits->parse_options('20%'));
    is($args->{nproc},  {kind => 'pct', value => 20}, 'nproc=20%');
    is($args->{nofile}, {kind => 'pct', value => 20}, 'nofile=20%');
    ok(!exists $args->{as}, 'as still off');
};

subtest 'per-dim explicit' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::UnixLimits->parse_options(
            'nproc=128', 'nofile=10%', 'as=512mb',
        ),
    );
    is($args->{nproc},  {kind => 'count', value => 128},           'nproc count');
    is($args->{nofile}, {kind => 'pct',   value => 10},            'nofile pct');
    is($args->{as},     {kind => 'bytes', value => 512 * 1024**2}, 'as bytes');
};

subtest 'config file' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "nproc": "256", "nofile": "10%", "as": "1gb", "name": "ulim" }
JSON
    close $fh;
    my $args = kvhash(Test2::Harness2::Resource::UnixLimits->parse_options('@' . $path));
    is($args->{nproc},  {kind => 'count', value => 256},     'nproc');
    is($args->{nofile}, {kind => 'pct',   value => 10},      'nofile');
    is($args->{as},     {kind => 'bytes', value => 1024**3}, 'as');
    is($args->{name},   'ulim', 'name');
};

subtest 'invalid' => sub {
    like(
        dies { Test2::Harness2::Resource::UnixLimits->parse_options('nproc=0') },
        qr/nproc/, 'zero nproc'
    );
    like(
        dies { Test2::Harness2::Resource::UnixLimits->parse_options('nofile=abc') },
        qr/nofile/, 'bad nofile'
    );
    like(
        dies { Test2::Harness2::Resource::UnixLimits->parse_options('as=512') },
        qr/as|expected NUMBER/, 'as without unit'
    );
};

done_testing;

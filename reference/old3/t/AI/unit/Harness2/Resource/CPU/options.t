use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Resource::CPU;

sub kvhash { my %h = @_; \%h }

subtest 'no args -> defaults' => sub {
    my $args = kvhash(Test2::Harness2::Resource::CPU->parse_options());
    is($args->{utilize_percent}, 80,    'default utilize=80');
    is($args->{name},            'cpu', 'default name');
};

subtest 'bare integer = utilize_percent' => sub {
    my $args = kvhash(Test2::Harness2::Resource::CPU->parse_options('70'));
    is($args->{utilize_percent}, 70, 'utilize=70');
};

subtest 'utilize= explicit' => sub {
    my $args = kvhash(Test2::Harness2::Resource::CPU->parse_options('utilize=50'));
    is($args->{utilize_percent}, 50, 'utilize=50');
};

subtest 'name= entry' => sub {
    my $args = kvhash(Test2::Harness2::Resource::CPU->parse_options('70', 'name=cpu_host'));
    is($args->{name}, 'cpu_host', 'custom name');
};

subtest 'config file' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "utilize_percent": 60, "name": "from_file" }
JSON
    close $fh;
    my $args = kvhash(Test2::Harness2::Resource::CPU->parse_options('@' . $path));
    is($args->{utilize_percent}, 60,          'from file');
    is($args->{name},            'from_file', 'name from file');
};

subtest 'inline overrides file' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "utilize_percent": 60 }
JSON
    close $fh;
    my $args = kvhash(Test2::Harness2::Resource::CPU->parse_options('@' . $path, '90'));
    is($args->{utilize_percent}, 90, 'inline wins');
};

subtest 'invalid' => sub {
    like(
        dies { Test2::Harness2::Resource::CPU->parse_options('0') },
        qr/utilize/, 'zero rejected'
    );
    like(
        dies { Test2::Harness2::Resource::CPU->parse_options('100') },
        qr/utilize/, '100 rejected'
    );
    like(
        dies { Test2::Harness2::Resource::CPU->parse_options('abc') },
        qr/abc/, 'non-numeric'
    );
};

done_testing;

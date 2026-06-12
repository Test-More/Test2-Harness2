use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Resource::Disk;

sub kvhash { my %h = @_; \%h }

subtest 'inline single mount' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Disk->parse_options('/tmp:25%'));
    is(
        $args->{mounts}, {
            '/tmp' => {min_free => {kind => 'pct', value => 25}},
        },
        'mount parsed'
    );
    ok(!exists $args->{poll_interval}, 'no poll_interval in output');
};

subtest 'multiple inline + byte unit' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::Disk->parse_options('/tmp:25%', '/var:1gb'),
    );
    is(
        $args->{mounts}, {
            '/tmp' => {min_free => {kind => 'pct',   value => 25}},
            '/var' => {min_free => {kind => 'bytes', value => 1024**3}},
        },
        'two mounts'
    );
};

subtest 'config file via @path' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{
  "mounts": {
    "/scratch": { "min_free": "2gb" }
  }
}
JSON
    close $fh;

    my $args = kvhash(
        Test2::Harness2::Resource::Disk->parse_options('@' . $path),
    );
    is(
        $args->{mounts}, {
            '/scratch' => {min_free => {kind => 'bytes', value => 2 * 1024**3}},
        },
        'config mounts'
    );
    ok(!exists $args->{poll_interval}, 'no poll_interval in output');
};

subtest 'inline overrides config (later wins)' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{
  "mounts": {
    "/tmp": { "min_free": "10%" },
    "/var": { "min_free": "1gb" }
  }
}
JSON
    close $fh;

    my $args = kvhash(
        Test2::Harness2::Resource::Disk->parse_options(
            '@' . $path,
            '/tmp:50%',
        ),
    );
    is(
        $args->{mounts}, {
            '/tmp' => {min_free => {kind => 'pct',   value => 50}},
            '/var' => {min_free => {kind => 'bytes', value => 1024**3}},
        },
        'inline /tmp wins'
    );
};

subtest 'resource-group key/value pairs are dropped' => sub {
    my $args = kvhash(
        Test2::Harness2::Resource::Disk->parse_options(
            slots       => 4,
            job_slots   => 1,
            classes     => {},
            utilize     => 80,
            no_resource => 0,
            '/tmp:25%',
        ),
    );
    ok(!exists $args->{slots},   'slots dropped');
    ok(!exists $args->{utilize}, 'utilize dropped');
    is(
        $args->{mounts}, {
            '/tmp' => {min_free => {kind => 'pct', value => 25}},
        },
        'mount still parsed'
    );
};

subtest 'invalid entry croaks with offender named' => sub {
    like(
        dies { Test2::Harness2::Resource::Disk->parse_options('not-a-spec') },
        qr/not-a-spec/, 'bare junk names entry'
    );
    like(
        dies { Test2::Harness2::Resource::Disk->parse_options('/tmp:abc') },
        qr/abc/, 'bad threshold names value'
    );
    like(
        dies { Test2::Harness2::Resource::Disk->parse_options('@/no/such/file') },
        qr{/no/such/file}, 'missing config file'
    );
};

subtest 'unknown config keys croak' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "munts": { "/tmp": { "min_free": "25%" } } }
JSON
    close $fh;

    like(
        dies { Test2::Harness2::Resource::Disk->parse_options('@' . $path) },
        qr/munts/, 'top-level typo'
    );

    my ($fh2, $path2) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh2} <<'JSON';
{ "mounts": { "/tmp": { "min_freeee": "25%" } } }
JSON
    close $fh2;

    like(
        dies { Test2::Harness2::Resource::Disk->parse_options('@' . $path2) },
        qr/min_freeee/, 'per-mount typo'
    );

    my ($fh3, $path3) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh3} <<'JSON';
{ "poll_interval": 5, "mounts": { "/tmp": { "min_free": "25%" } } }
JSON
    close $fh3;

    like(
        dies { Test2::Harness2::Resource::Disk->parse_options('@' . $path3) },
        qr/poll_interval/, 'poll_interval no longer recognised'
    );
};

done_testing;

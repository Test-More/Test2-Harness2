use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Resource::Disk;

sub kvhash { my %h = @_; \%h }

subtest 'inline single mount' => sub {
    my $args = kvhash(Test2::Harness2::Resource::Disk->parse_options('/tmp:25%'));
    is($args->{poll_interval}, 5, 'default poll_interval');
    is(
        $args->{mounts}, {
            '/tmp' => {min_free => {kind => 'pct', value => 25}},
        },
        'mount parsed'
    );
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
  "poll_interval": 11,
  "mounts": {
    "/scratch": { "min_free": "2gb" }
  }
}
JSON
    close $fh;

    my $args = kvhash(
        Test2::Harness2::Resource::Disk->parse_options('@' . $path),
    );
    is($args->{poll_interval}, 11, 'poll_interval from config');
    is(
        $args->{mounts}, {
            '/scratch' => {min_free => {kind => 'bytes', value => 2 * 1024**3}},
        },
        'config mounts'
    );
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
};

subtest 'explicit poll_interval beats config file' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print {$fh} <<'JSON';
{ "poll_interval": 11, "mounts": { "/tmp": { "min_free": "25%" } } }
JSON
    close $fh;

    # User passing the same value as the default (5) must still win
    # over the file's 11.
    my $args = kvhash(
        Test2::Harness2::Resource::Disk->parse_options(
            poll_interval => 5,
            '@' . $path,
        ),
    );
    is($args->{poll_interval}, 5, 'explicit poll_interval=5 wins over file 11');

    # User-supplied non-default value also wins.
    my $args2 = kvhash(
        Test2::Harness2::Resource::Disk->parse_options(
            poll_interval => 7,
            '@' . $path,
        ),
    );
    is($args2->{poll_interval}, 7, 'explicit poll_interval=7 wins over file 11');

    # No user value: file wins.
    my $args3 = kvhash(
        Test2::Harness2::Resource::Disk->parse_options('@' . $path),
    );
    is($args3->{poll_interval}, 11, 'no user value: file wins');

    # Neither user nor file: default 5.
    my $args4 = kvhash(
        Test2::Harness2::Resource::Disk->parse_options('/tmp:25%'),
    );
    is($args4->{poll_interval}, 5, 'no user no file: default 5');
};

done_testing;

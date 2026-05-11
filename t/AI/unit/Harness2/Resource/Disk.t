use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Resource::Disk;

# Real init requires Filesys::Df; skip the whole file when absent so
# a dev box without the optional dep can still run the rest of the
# suite.
my $have_df = eval { require Filesys::Df; 1 };
skip_all "Filesys::Df not installed" unless $have_df;

subtest 'init requires non-empty mounts' => sub {
    like(
        dies { Test2::Harness2::Resource::Disk->new() },
        qr/'mounts' is required/, 'no mounts'
    );
    like(
        dies { Test2::Harness2::Resource::Disk->new(mounts => {}) },
        qr/'mounts' is required/, 'empty mounts'
    );
};

subtest 'init rejects bad poll_interval' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    like(
        dies {
            Test2::Harness2::Resource::Disk->new(
                mounts        => {$tmp => {min_free => {kind => 'pct', value => 25}}},
                poll_interval => 0,
            );
        },
        qr/poll_interval/,
        'zero rejected'
    );
    like(
        dies {
            Test2::Harness2::Resource::Disk->new(
                mounts        => {$tmp => {min_free => {kind => 'pct', value => 25}}},
                poll_interval => 'abc',
            );
        },
        qr/poll_interval/,
        'non-numeric rejected'
    );
};

subtest 'init croaks on missing mount path' => sub {
    like(
        dies {
            Test2::Harness2::Resource::Disk->new(
                mounts => {
                    '/no/such/path/should/exist' => {
                        min_free => {kind => 'pct', value => 25},
                    },
                },
            );
        },
        qr{/no/such/path/should/exist},
        'missing path named'
    );
};

subtest 'init succeeds for a real mount' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $r   = Test2::Harness2::Resource::Disk->new(
        mounts => {$tmp => {min_free => {kind => 'pct', value => 25}}},
    );
    is($r->resource_name, 'disk', 'name');
    is($r->poll_interval, 5,      'default poll_interval');
};

done_testing;

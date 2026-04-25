use strict;
use warnings;

use Test2::V0;

use App::Yath2::Options::LogArchive;

# Minimal stub mimicking the settings shape passed to resolve_dict_path:
# a settings object that responds to ->log_archive with a hashref-like
# proxy whose accessors return the parsed option values. This keeps
# the unit test free of the full Yath options-parsing machinery.
package _OptStub {
    sub new { my $class = shift; bless {@_} => $class }
    sub no_zstd_dict { $_[0]->{no_zstd_dict} }
    sub zstd_dict    { $_[0]->{zstd_dict} }
}
package _SettingsStub {
    sub new { my $class = shift; bless {@_} => $class }
    sub log_archive { $_[0]->{log_archive} }
}

subtest 'resolve_dict_path returns explicit path' => sub {
    my $opts = _OptStub->new(zstd_dict => '/tmp/custom.dict', no_zstd_dict => 0);
    my $set  = _SettingsStub->new(log_archive => $opts);
    is(
        App::Yath2::Options::LogArchive->resolve_dict_path($set),
        '/tmp/custom.dict',
        'explicit path returned',
    );
};

subtest 'resolve_dict_path returns undef for --no-zstd-dict' => sub {
    my $opts = _OptStub->new(zstd_dict => undef, no_zstd_dict => 1);
    my $set  = _SettingsStub->new(log_archive => $opts);
    is(
        App::Yath2::Options::LogArchive->resolve_dict_path($set),
        undef,
        'dict-less mode returns undef',
    );
};

subtest 'resolve_dict_path croaks on conflict' => sub {
    my $opts = _OptStub->new(zstd_dict => '/tmp/x.dict', no_zstd_dict => 1);
    my $set  = _SettingsStub->new(log_archive => $opts);
    like(
        dies { App::Yath2::Options::LogArchive->resolve_dict_path($set) },
        qr/mutually exclusive/,
        'both options at once is an error',
    );
};

done_testing;

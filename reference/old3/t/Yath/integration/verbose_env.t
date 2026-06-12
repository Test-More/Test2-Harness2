# HARNESS2: conflicts yath
use Test2::V0;

use Config qw/%Config/;
use File::Temp qw/tempfile/;
use File::Spec;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;
use Test2::Harness2::Util::File::JSONL;

use Test2::Harness2::Util       qw/clean_path/;
use Test2::Harness2::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Make it very wrong to start
local $ENV{T2_HARNESS_IS_VERBOSE} = 99;
local $ENV{HARNESS_IS_VERBOSE} = 99;

yath(
    command => 'test',
    args    => [File::Spec->catfile($dir, "not_verbose.tx")],
    exit    => F(),
);

yath(
    command => 'test',
    args    => ['-v', File::Spec->catfile($dir, "verbose1.tx")],
    exit    => F(),
);

yath(
    command => 'test',
    args    => ['-vv', File::Spec->catfile($dir, "verbose2.tx")],
    exit    => F(),
);

done_testing;

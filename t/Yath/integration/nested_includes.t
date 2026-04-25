# HARNESS-CONFLICTS YATH
use Test2::V0;
plan skip_all => "TODO: nested includes / HARNESS-* parsing not aligned with current finder";
__END__

use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;
use Test2::Harness2::Util::File::JSONL;

use Test2::Harness2::Util::JSON qw/decode_json/;
my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

if ($ENV{T2_HARNESS_INCLUDES}) {
    $ENV{T2_HARNESS_INCLUDES} .= ";/foo;/bar;/baz";
}
else {
    $ENV{T2_HARNESS_INCLUDES} = "/foo;/bar;/baz";
}

yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    exit    => F(),
    test    => sub {
        my $out = shift;
        use Data::Dumper;
        local $Data::Dumper::Sortkeys = 1;
    },
);



done_testing;

# HARNESS2: conflicts yath
use Test2::V0;
plan skip_all => "TODO: --event-timeout flag and verbose buffer rendering not implemented";
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

my $out1 = yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-v', '--event-timeout' => 2],
    log     => 1,
    exit    => T(),
    test    => sub {
        my $out = shift;

        like($out->{output}, qr/\+ outer 1/, "See outermost events");
        like($out->{output}, qr/> \+ inner 1/, "See inner events");
        like($out->{output}, qr/> > \+ deeper 1/, "See deeper event");
        like($out->{output}, qr/> > > \+ even deeper 1/, "See deepest events");
        like($out->{output}, qr/> > > > diag/, "See last event");
    },
);

done_testing;

use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;
use Test2::Harness2::Util::File::JSONL;

use Test2::Harness2::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    pre     => ['-p+SmokePlugin'],
    args    => [$dir, '--ext=tx'],
    log     => 1,
    exit    => 0,
    test    => \&the_test,
);

yath(
    command => 'test',
    pre     => ['-p+SmokePlugin'],
    args    => [$dir, '-j3', '--ext=tx'],
    log     => 1,
    exit    => 0,
    test    => \&the_test,
);

sub the_test {
    my $out = shift;
    my $log = $out->{log};

    my @order;
    my @events = $log->poll();
    while (@events) {
        if (my $event = shift @events) {
            my $f = $event->{facet_data};

            if (my $l = $f->{harness_job_start}) {
                push @order => $l;
            }
        }

        # Check for additional events, probably should not have any, but we may hit
        # a buffering limit in the log reader and need additional polls.
        push @events => $log->poll;
    }

    # Order by start time. Under concurrency (-j3) the fourth smoke test and the
    # first non-smoke test are dispatched back-to-back as the first slot frees,
    # so their start stamps can tie -- the smoke/non-smoke boundary at index 3/4
    # is not a stable split. What IS guaranteed regardless of -j: the initial
    # wave (the first starts, up to the slot count) is always smoke, and the
    # final wave is always non-smoke. Assert that robust invariant plus full
    # membership, instead of a strict positional split that races on the tie.
    @order = sort { $a->{stamp} <=> $b->{stamp} } @order;
    my @files = map { $_->{rel_file} } @order;

    is(scalar(@files), 8, "All 8 tests started");

    is(
        [@files],
        bag {
            item match qr/a\.tx$/;
            item match qr/c\.tx$/;
            item match qr/e\.tx$/;
            item match qr/g\.tx$/;
            item match qr/b\.tx$/;
            item match qr/d\.tx$/;
            item match qr/f\.tx$/;
            item match qr/h\.tx$/;
            end;
        },
        "All four smoke and four non-smoke tests ran"
    );

    # First wave (>= the -j3 slot count) is smoke; final wave is non-smoke. The
    # racy boundary pair (indices 3 and 4) is intentionally left unconstrained.
    like($files[$_], qr/[aceg]\.tx$/, "Start #$_ is a smoke test (smoke runs first)")
        for 0 .. 2;
    like($files[$_], qr/[bdfh]\.tx$/, "Start #$_ is a non-smoke test (non-smoke runs last)")
        for 5 .. 7;
}

done_testing;

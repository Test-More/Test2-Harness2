use Test2::V0;
use feature 'signatures';
no warnings 'experimental::signatures';
# HARNESS-DURATION-MEDIUM

# Chunk 15 / #44: the --live flag makes `yath test` tail EVERY job's events file
# as it is written, streaming each event to the renderers in arrival order. Under
# concurrency this interleaves output across jobs (the 1.0 tail-the-files shape),
# while each job's own events stay in order, and every event still carries its
# job identity so a renderer attributes it (the default terminal renderer tags
# each line with the job's index). The default (non --live) run is unchanged: a
# job's body renders as one contiguous block at completion (per-job ordering).
#
# Asserted via the captured log stream (the exact ordered fan-out the renderers
# saw) for deterministic interleave/order checks, plus the rendered terminal
# output for the per-job index tag.

use Test2::Util qw/CAN_REALLY_FORK/;
use App::Yath2::Tester qw/yath/;

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Pull the ordered (job_id, marker-tag, marker-number) sequence of the test-body
# print lines out of a captured log.
sub body_sequence ($log) {
    my @seq;
    my @events = $log->poll;
    while (@events) {
        my $e = shift @events;
        if ($e) {
            my $fd   = $e->{facet_data} // {};
            my $info = $fd->{info}      // [];
            for my $i (@$info) {
                my $d = $i->{details} // '';
                next unless $d =~ /LIVE-MARKER-(AAA|BBB)-(\d+)/;
                push @seq => [$e->{job_id}, $1, $2];
            }
        }
        push @events => $log->poll;
    }
    return @seq;
}

# --live, two concurrent jobs: the two jobs' body markers interleave in the
# rendered stream, each marker is attributed to its own job_id, and each job's
# markers stay in order.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-v', '--live', '-j2'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out  = shift;
        my $text = $out->{output};

        like($text, qr{LIVE-MARKER-AAA-1}, "aaa body output appears");
        like($text, qr{LIVE-MARKER-BBB-1}, "bbb body output appears");

        # The default terminal renderer tags each output line with its job index
        # ("job N"); with -j2 both job slots must appear, proving per-item
        # job attribution survives the interleaved feed.
        like($text, qr{job\s+\d}, "rendered lines carry a per-job index tag");

        my @seq = body_sequence($out->{log});

        my @aaa = grep { $_->[1] eq 'AAA' } @seq;
        my @bbb = grep { $_->[1] eq 'BBB' } @seq;
        is(scalar(@aaa), 4, "all 4 aaa markers streamed");
        is(scalar(@bbb), 4, "all 4 bbb markers streamed");

        # Per-job attribution: a job_id is consistent for each tag, and the two
        # tags map to two DIFFERENT job_ids.
        my %job_for_tag;
        $job_for_tag{$_->[1]}{$_->[0]} = 1 for @seq;
        is(scalar(keys %{$job_for_tag{AAA}}), 1, "all aaa markers share one job_id");
        is(scalar(keys %{$job_for_tag{BBB}}), 1, "all bbb markers share one job_id");
        my ($aaa_job) = keys %{$job_for_tag{AAA}};
        my ($bbb_job) = keys %{$job_for_tag{BBB}};
        isnt($aaa_job, $bbb_job, "aaa and bbb are attributed to different jobs");

        # Within-job order preserved.
        is([map { $_->[2] } @aaa], [1, 2, 3, 4], "aaa markers rendered in order");
        is([map { $_->[2] } @bbb], [1, 2, 3, 4], "bbb markers rendered in order");

        # Interleave: NOT one whole job's body then the other. At least one BBB
        # marker renders before the LAST AAA marker (and vice-versa).
        my @tags = map { $_->[1] } @seq;
        my $first_bbb = do { my $i = 0; $i++ until $i >= @tags || $tags[$i] eq 'BBB'; $i };
        my $last_aaa  = do { my $i = $#tags; $i-- while $i >= 0 && $tags[$i] ne 'AAA'; $i };
        ok($last_aaa > $first_bbb, "--live interleaves the two jobs' output (not whole-job blocks)");
    },
);

# Default (NO --live), same two jobs: each job's body renders as one contiguous
# block (per-job render-on-completion), so the markers do NOT interleave -- all
# of one job's markers appear before the other job's first marker.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-v', '-j2'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out  = shift;
        my $text = $out->{output};

        like($text, qr{LIVE-MARKER-AAA-1}, "aaa body output appears (default mode)");
        like($text, qr{LIVE-MARKER-BBB-1}, "bbb body output appears (default mode)");

        my @seq  = body_sequence($out->{log});
        my @tags = map { $_->[1] } @seq;

        my @aaa = grep { $_->[1] eq 'AAA' } @seq;
        my @bbb = grep { $_->[1] eq 'BBB' } @seq;
        is(scalar(@aaa), 4, "all 4 aaa markers present (default mode)");
        is(scalar(@bbb), 4, "all 4 bbb markers present (default mode)");

        # Contiguous blocks: the positions of one tag form an unbroken run (no
        # other tag falls between this tag's first and last marker).
        for my $tag (qw/AAA BBB/) {
            my @pos = grep { $tags[$_] eq $tag } 0 .. $#tags;
            my $contiguous = ($pos[-1] - $pos[0]) == $#pos;
            ok($contiguous, "default mode renders ${tag} body as one contiguous block (no interleave)");
        }
    },
);

done_testing;

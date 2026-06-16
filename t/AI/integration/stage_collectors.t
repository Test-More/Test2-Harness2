use Test2::V0;

use App::Yath2::Tester qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;

# Chunk 4b: each preload stage of the transient `yath test` runner runs under
# its own non-test collector, writing stage-<name>-events.jsonl.zst. The
# gatherer reads those per-stage events files, so output a stage produces while
# preloading (here, markers printed by StageMarker's MARK stage) must still show
# up in the rendered output -- before 4b that output rode the runner's shared
# captured pipe; now it travels through the stage's own collector.

skip_all "Cannot fork, skipping stage-collector test" unless CAN_REALLY_FORK;
skip_all "This test requires forking" if $ENV{T2_NO_FORK};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PStageMarker'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{PASSED.*a_test\.tx}, 'ran the stage-routed test file');

        # STDOUT from a collected stage is surfaced as an INTERNAL line; STDERR
        # the same but flagged debug. Both must be visible.
        like($out->{output}, qr{STAGE-MARKER-STDOUT-VISIBLE}, 'stage STDOUT reached rendered output');
        like($out->{output}, qr{STAGE-MARKER-STDERR-VISIBLE}, 'stage STDERR reached rendered output');
    },
);

done_testing;

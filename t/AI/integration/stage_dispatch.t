use Test2::V0;

use App::Yath2::Tester qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;

# Chunk 5d: each global preload stage of the transient `yath test` runner is a
# service that binds preload-<stage>.socket and accepts dispatched jobs; the
# runner's in-process scheduler connects out to that socket to dispatch a test
# instead of enqueuing a start_task into dispatch.jsonl for the stage to poll.
#
# This drives two named, non-default stages (ALPHA, BETA) with file_stage routing.
# Each stage preloads a stage-specific marker; each test asserts ONLY its own
# stage's marker is set. A passing assertion means the job was forked from the
# correct stage's preloaded interpreter -- i.e. the runner dispatched it to that
# stage's socket and the stage forked it -- exercising the full socket-dispatch
# path end to end.

skip_all "Cannot fork, skipping stage-dispatch test" unless CAN_REALLY_FORK;
skip_all "This test requires forking" if $ENV{T2_NO_FORK};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PStageDispatch'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{PASSED.*alpha\.tx}, 'alpha.tx passed (dispatched to the ALPHA stage)');
        like($out->{output}, qr{PASSED.*beta\.tx},  'beta.tx passed (dispatched to the BETA stage)');
    },
);

done_testing;

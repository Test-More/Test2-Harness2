use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;
use Test2::Harness2::Util::File::JSONL;

use Test2::Harness2::Util::JSON qw/decode_json/;

skip_all "This test is not run under automated testing"
    if $ENV{AUTOMATED_TESTING};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(command => 'start', exit => 0);

yath(
    command => 'run',
    args    => [$dir, '--ext=tx', '--ext=txx'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
        like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");
    },
);


yath(
    command => 'run',
    args    => [$dir, '--ext=tx'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        unlike($out->{output}, qr{fail\.tx}, "'fail.tx' was not seen when reading the output");
        like($out->{output}, qr{PASSED.*pass\.tx}, "'pass.tx' was not seen as a failure when reading the output");
    },
);

yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^\s*Found: .*yath-runner\.sock$/m, "Found the discovery symlink");
        like($out->{output}, qr/^\s*PID: /m,                       "Found the PID");
        like($out->{output}, qr/^\s*Dir: /m,                       "Found the Dir");
    },
);

# Chunk 6.1-2: status/ps now query the runner over runner.socket (the runner is
# the state authority) instead of reading dispatch.jsonl/jobs.jsonl. Exercise them
# against the live idle runner: the stage table is served from the runner's
# canonical state.
yath(
    command => 'status',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/\*\*\*\* Runner Stages: \*\*\*\*/, "status reports runner stages over the socket");
    },
);

yath(
    command => 'ps',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/Running Processes/, "ps reports running processes over the socket");
        like($out->{output}, qr/Runner Stage/,      "ps lists a runner stage over the socket");
    },
);

# A no-preload persistent runner holds no preloaded interpreter state and no
# longer self-restarts: it is a pure scheduler/orchestrator. `yath reload` (a
# SIGHUP) would be a no-op here -- the runner keeps running and does not re-exec.
# (To pick up code changes a no-preload persistent runner must be stopped and
# started again; reload only does work when a preload-root is hosting stages,
# which re-execs the preload tree.) Rather than falsely report success, `yath
# reload` detects the no-preload runner and exits 2 with a warning (ticket TODO-114);
# it does NOT signal the runner, so the runner keeps serving unchanged.
yath(
    command => 'reload',
    test    => sub {
        my $out = shift;
        is($out->{exit} >> 8, 2, "reload of a no-preload runner exits 2 (nothing to reload)");
        like($out->{output}, qr/no preload stages/, "warns that the runner has no preload stages");
    },
);

# Confirm the runner survived the reload no-op and is still serving its socket.
yath(
    command => 'status',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/\*\*\*\* Runner Stages: \*\*\*\*/, "runner still serving after a no-op reload");
    },
);

yath(
    command => 'run',
    args => [$dir, '--ext=txx'],
    exit => T(),
    test => sub {
        my $out = shift;

        like($out->{output}, qr{FAILED.*fail\.tx}, "'fail.tx' was seen as a failure when reading the output");
        unlike($out->{output}, qr{pass\.tx}, "'pass.tx' was not seen when reading the output");
    },
);

yath(
    command => 'run',
    args => [$dir, '-vvv'],
    exit => T(),
    test => sub {
        my $out = shift;

        like($out->{output}, qr/No tests were seen!/, "Got error message");
    },
);

yath(command => 'stop', exit => 0);

yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/No persistent harness was found for the current path\./, "No active runner");
    },
);

done_testing;

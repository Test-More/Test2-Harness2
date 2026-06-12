use Test2::V0;
use Atomic::Pipe;
use Config;
use Cpanel::JSON::XS qw/decode_json/;
use POSIX qw/_exit/;
use Scalar::Util ();

use Test2::Harness2::Util::EventEmitter;

# After the new_log_refactor:
#  - emit_event no longer stamps event_id / stamp / pid on the in-memory
#    event hash, and no longer mirrors event_id into harness.event_id.
#  - emit_raw still produces a wire-level event_id for the STDOUT-vs-STDERR
#    sync handshake the collector relies on, but that id is NOT persisted
#    onto the in-memory event hash and NOT written into harness.event_id.
#  - STDERR sync markers still carry an event_id that matches the wire id
#    of the matching STDOUT JSON burst.

subtest 'emit_event writes a JSON burst readable by Atomic::Pipe' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

    $emitter->emit_event(kind => 'test_event', note => 'hello');

    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'got a message-type item');
    ok($msg, 'message has content');

    my $payload = decode_json($msg);
    is($payload->{facet_data}{harness}{kind}, 'test_event', 'custom kind field preserved');
    is($payload->{facet_data}{harness}{note}, 'hello',      'custom note field preserved');

    # Wire-level sync id appears on the JSON burst (the collector uses
    # it to pair the STDOUT burst with its STDERR sync marker).
    ok($payload->{event_id}, 'event_id present on the wire JSON');

    # No identifier mirrors / no top-level mirrors in the harness facet.
    ok(!exists $payload->{facet_data}{harness}{event_id}, 'no harness.event_id mirror');
    ok(!exists $payload->{facet_data}{harness}{stamp},    'no harness.stamp mirror');
    ok(!exists $payload->{facet_data}{harness}{run_id},   'no ambient run_id stamped');
    ok(!exists $payload->{facet_data}{harness}{job_id},   'no ambient job_id stamped');
    ok(!exists $payload->{facet_data}{harness}{job_try},  'no ambient job_try stamped');
};

subtest 'emit_event returns the wire-level sync id' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

    my $id = $emitter->emit_event(kind => 'ping');
    ok($id, 'emit_event returns a sync id');
    like($id, qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i,
        'sync id looks like a UUID');
};

subtest 'default stdout_pipe wraps STDOUT; stderr_pipe follows T2_HARNESS2_PIPE_COUNT' => sub {
    pipe(my $out_r, my $out_w) or die "pipe stdout: $!";
    pipe(my $err_r, my $err_w) or die "pipe stderr: $!";

    {
        local *STDOUT = $out_w;
        local *STDERR = $err_w;
        local $ENV{T2_HARNESS2_PIPE_COUNT} = 1;
        my $e = Test2::Harness2::Util::EventEmitter->new;
        isa_ok($e->stdout_pipe, ['Atomic::Pipe'], 'stdout_pipe wrapped from STDOUT');
        ok(!defined $e->stderr_pipe,
            'stderr_pipe stays empty when pipe count is 1 (merged)');
    }

    {
        local *STDOUT = $out_w;
        local *STDERR = $err_w;
        local $ENV{T2_HARNESS2_PIPE_COUNT} = 2;
        my $e = Test2::Harness2::Util::EventEmitter->new;
        isa_ok($e->stdout_pipe, ['Atomic::Pipe'], 'stdout_pipe wrapped from STDOUT');
        isa_ok($e->stderr_pipe, ['Atomic::Pipe'],
            'stderr_pipe wrapped from STDERR when pipe count is 2');
    }

    {
        local *STDOUT = $out_w;
        local *STDERR = $err_w;
        local %ENV = %ENV;
        delete $ENV{T2_HARNESS2_PIPE_COUNT};
        my $e = Test2::Harness2::Util::EventEmitter->new;
        isa_ok($e->stdout_pipe, ['Atomic::Pipe'], 'stdout_pipe still defaults');
        ok(!defined $e->stderr_pipe,
            'stderr_pipe stays empty when env var is unset');
    }
};

subtest 'filehandle inputs are promoted to Atomic::Pipe' => sub {
    pipe(my $out_r, my $out_w) or die "pipe stdout: $!";
    pipe(my $err_r, my $err_w) or die "pipe stderr: $!";

    my $e = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe => $out_w,
        stderr_pipe => $err_w,
    );
    isa_ok($e->stdout_pipe, ['Atomic::Pipe'], 'plain filehandle promoted for stdout');
    isa_ok($e->stderr_pipe, ['Atomic::Pipe'], 'plain filehandle promoted for stderr');
};

subtest 'pre-built Atomic::Pipe is used verbatim' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $e = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);
    is($e->stdout_pipe, $w, 'constructed pipe is stored without re-wrapping');
};

subtest 'std returns a process-wide cached instance, rebuilt after fork' => sub {
    skip_all "fork required" unless $Config{d_fork};

    pipe(my $out_r, my $out_w) or die "pipe stdout: $!";

    my $first;
    my $second;
    {
        local *STDOUT = $out_w;
        local $ENV{T2_HARNESS2_PIPE_COUNT} = 1;
        $first  = Test2::Harness2::Util::EventEmitter->std;
        $second = Test2::Harness2::Util::EventEmitter->std;
    }
    is($first,  $second, 'same instance across two calls in the parent');
    isa_ok($first, ['Test2::Harness2::Util::EventEmitter'], 'std returns an emitter');

    pipe(my $reply_r, my $reply_w) or die "pipe reply: $!";
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        close $reply_r;
        local *STDOUT = $out_w;
        local $ENV{T2_HARNESS2_PIPE_COUNT} = 1;
        my $child = Test2::Harness2::Util::EventEmitter->std;
        syswrite($reply_w, Scalar::Util::refaddr($child) . "\n");
        close $reply_w;
        POSIX::_exit(0);
    }
    close $reply_w;
    waitpid($pid, 0);

    my $child_addr = <$reply_r>;
    chomp $child_addr;
    close $reply_r;

    isnt($child_addr, Scalar::Util::refaddr($first),
        'child rebuilds a distinct instance after fork');
};

subtest 'no top-level pid stamp on the persisted event' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);
    $emitter->emit_event(kind => 'test');

    my ($type, $msg) = $r->get_line_burst_or_data();
    my $payload = decode_json($msg);
    ok(!exists $payload->{pid}, 'no top-level pid mirror on event');
};

subtest 'stderr sync marker matches the wire-level event_id' => sub {
    my ($r,    $w)    = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($se_r, $se_w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe => $w,
        stderr_pipe => $se_w,
    );

    my $id = $emitter->emit_event(kind => 'with_stderr');

    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'stdout pipe got a message');
    my $payload = decode_json($msg);
    is($payload->{event_id},                  $id,           'wire event_id matches return value');
    is($payload->{facet_data}{harness}{kind}, 'with_stderr', 'kind field preserved');

    my ($se_type, $se_msg) = $se_r->get_line_burst_or_data();
    is($se_type, 'message', 'stderr pipe got a message');
    my $marker = decode_json($se_msg);
    is($marker->{event_id}, $id, 'stderr marker event_id matches the wire id');
    ok(!exists $marker->{facet_data}, 'stderr marker has no facet_data');
};

subtest 'emit_raw writes the event verbatim with a wire-level sync id' => sub {
    my ($r,    $w)    = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($se_r, $se_w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe => $w,
        stderr_pipe => $se_w,
    );

    my $raw = {facet_data => {harness => {run_id => 'r0'}, assert => {pass => 1}}};
    my $ret = $emitter->emit_raw($raw);
    like($ret, qr/\A[0-9a-f]{8}-/i, 'emit_raw returns generated wire-level sync id');

    # The wire-level sync id must NOT remain on the in-memory event after
    # emit_raw completes -- the field is the emitter's transient sync
    # protocol and is cleaned up before returning to the caller.
    ok(!exists $raw->{event_id}, 'event_id stripped from in-memory event after emit');

    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'stdout got a message');
    my $payload = decode_json($msg);
    is($payload->{event_id},                  $ret,  'wire payload has the sync id');
    is($payload->{facet_data}{harness}{run_id}, 'r0', 'harness facet passed through verbatim');
    is($payload->{facet_data}{assert}{pass},    1,    'assert.pass intact');

    # No mirroring into harness.event_id either.
    ok(!exists $payload->{facet_data}{harness}{event_id},
        'wire payload has no harness.event_id mirror');

    my ($se_type, $se_msg) = $se_r->get_line_burst_or_data();
    is($se_type, 'message', 'stderr got a message');
    my $marker = decode_json($se_msg);
    is($marker->{event_id}, $ret, 'stderr marker event_id matches the wire id');
};

done_testing;

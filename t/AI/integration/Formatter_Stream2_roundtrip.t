use Test2::V0;
use POSIX qw/_exit/;
use IO::Handle;
use Atomic::Pipe;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::IPC qw/apply_atomic_pipe_compression/;

# Round-trip integration: spawn a fresh perl process that uses
# Test2::Formatter::Stream2 as its Test2 formatter, capture its
# STDOUT (event bursts) and STDERR (sync markers) through Atomic::Pipe,
# decode the events, and confirm the wire shape.

my ($r_out, $w_out) = Atomic::Pipe->pair(mixed_data_mode => 1);
apply_atomic_pipe_compression($r_out);
my ($r_err, $w_err) = Atomic::Pipe->pair(mixed_data_mode => 1);
apply_atomic_pipe_compression($r_err);

my $child_prog = <<'CHILD';
use Test2::Tools::Basic qw/ok done_testing diag/;
ok(1, 'roundtrip event one');
ok(1, 'roundtrip event two');
ok(1, 'roundtrip event three');
done_testing();
CHILD

my $pid = fork;
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
    open(STDOUT, '>&', $w_out->wh) or _exit(10);
    STDOUT->autoflush(1);
    open(STDERR, '>&', $w_err->wh) or _exit(11);
    STDERR->autoflush(1);

    $ENV{T2_HARNESS2_PIPE_COUNT} = 2;
    $ENV{T2_FORMATTER}           = 'Stream2';

    exec($^X, '-Ilib', '-e', $child_prog) or _exit(12);
}

undef $w_out;
undef $w_err;

waitpid($pid, 0);
my $status = $? >> 8;
is($status, 0, "child exited cleanly (status=$status)");

sub drain {
    my ($pipe) = @_;
    my @msgs;
    while (1) {
        my ($type, $data) = $pipe->get_line_burst_or_data;
        last unless defined $type;
        push @msgs, [$type, $data];
    }
    return @msgs;
}

my @out_msgs = drain($r_out);
my @err_msgs = drain($r_err);

my @events  = map { decode_json($_->[1]) } grep { $_->[0] eq 'message' } @out_msgs;
my @syncs   = map { decode_json($_->[1]) } grep { $_->[0] eq 'message' } @err_msgs;

ok(@events > 0, 'received event bursts on stdout');
is(scalar(@events), scalar(@syncs), 'one stderr sync marker per stdout event');

for my $i (0 .. $#events) {
    is(
        $events[$i]->{event_id},
        $syncs[$i]->{event_id},
        "event $i is paired with its stderr sync marker by event_id",
    );
}

# Confirm the wire actually carried Test2 assertion facets.
my @asserts = grep { $_->{facet_data}->{assert} } @events;
ok(scalar(@asserts) >= 3, 'got at least three assertion events');
ok($asserts[0]->{facet_data}->{assert}->{pass}, 'first assertion is a pass');

# Confirm a plan landed.
my ($plan) = grep { $_->{facet_data}->{plan} } @events;
ok($plan, 'plan facet event present in stream');

done_testing;

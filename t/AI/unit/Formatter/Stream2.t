use Test2::V0;
use POSIX qw/_exit/;
use IO::Handle;
use Atomic::Pipe;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::IPC qw/apply_atomic_pipe_compression/;

require Test2::Formatter::Stream2;

subtest hide_buffered_is_zero => sub {
    is(Test2::Formatter::Stream2->hide_buffered, 0, 'class method returns 0');
};

subtest init_requires_collector_env => sub {
    local %ENV = %ENV;
    delete $ENV{T2_HARNESS2_PIPE_COUNT};
    like(
        dies { Test2::Formatter::Stream2->new },
        qr/T2_HARNESS2_PIPE_COUNT is not set/,
        'init confesses when env signal missing',
    );
};

sub fork_emit {
    my ($pipe_count, $cb) = @_;

    my ($r_out, $w_out) = Atomic::Pipe->pair(mixed_data_mode => 1);
    apply_atomic_pipe_compression($r_out);
    my ($r_err, $w_err);
    if ($pipe_count > 1) {
        ($r_err, $w_err) = Atomic::Pipe->pair(mixed_data_mode => 1);
        apply_atomic_pipe_compression($r_err);
    }

    my $pid = fork;
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        open(STDOUT, '>&', $w_out->wh) or _exit(10);
        STDOUT->autoflush(1);
        if ($pipe_count > 1) {
            open(STDERR, '>&', $w_err->wh) or _exit(11);
            STDERR->autoflush(1);
        }
        $ENV{T2_HARNESS2_PIPE_COUNT} = $pipe_count;

        my $ok = eval { $cb->(); 1 };
        _exit($ok ? 0 : 99);
    }

    undef $w_out;
    undef $w_err if $w_err;

    waitpid($pid, 0);
    my $status = $? >> 8;
    return ($status, $r_out, $r_err);
}

subtest single_pipe_emit => sub {
    my ($status, $r) = fork_emit(1, sub {
        my $fmt = Test2::Formatter::Stream2->new;
        $fmt->write(undef, 1, {assert => {pass => 1, details => 'ok'}});
    });
    is($status, 0, 'child exited cleanly');

    my (undef, $msg) = $r->get_line_burst_or_data;
    my $event = decode_json($msg);
    ok($event->{event_id}, 'wire event_id present');
    is($event->{facet_data}->{assert}->{pass},    1,    'assert.pass round-tripped');
    is($event->{facet_data}->{assert}->{details}, 'ok', 'assert.details round-tripped');
};

subtest two_pipe_sync_marker => sub {
    my ($status, $r_out, $r_err) = fork_emit(2, sub {
        my $fmt = Test2::Formatter::Stream2->new;
        $fmt->write(undef, 1, {assert => {pass => 1}});
    });
    is($status, 0, 'child exited cleanly');

    my (undef, $o_msg) = $r_out->get_line_burst_or_data;
    my (undef, $e_msg) = $r_err->get_line_burst_or_data;
    my $out = decode_json($o_msg);
    my $err = decode_json($e_msg);

    is($out->{event_id}, $err->{event_id}, 'stderr sync marker matches stdout event_id');
    is($out->{facet_data}->{assert}->{pass}, 1, 'main burst still carries facet_data');
};

subtest encoding_control_event => sub {
    my ($status, $r) = fork_emit(1, sub {
        my $fmt = Test2::Formatter::Stream2->new;
        $fmt->encoding('UTF-8');
        is($fmt->encoding, 'UTF-8', 'encoding getter returns set value')
            if defined &is;    # in-child diag is fine; result is ignored
    });
    is($status, 0, 'child exited cleanly');

    my (undef, $msg) = $r->get_line_burst_or_data;
    my $event = decode_json($msg);
    is(
        $event->{facet_data}->{control}->{encoding},
        'UTF-8',
        'encoding() emits a control facet event',
    );
};

subtest write_with_event_object => sub {
    my ($status, $r) = fork_emit(1, sub {
        require Test2::Event::Ok;
        my $fmt = Test2::Formatter::Stream2->new;
        my $ev  = Test2::Event::Ok->new(pass => 1, name => 'demo');
        $fmt->write($ev, 3);
    });
    is($status, 0, 'child exited cleanly');

    my (undef, $msg) = $r->get_line_burst_or_data;
    my $event = decode_json($msg);
    ok($event->{facet_data}, 'facet_data present');
    is(
        $event->{facet_data}->{assert}->{pass},
        1,
        'event-object write preserves assert facet',
    );
};

done_testing;

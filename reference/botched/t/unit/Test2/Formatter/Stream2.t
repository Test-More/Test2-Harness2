use Test2::V0;
use Time::HiRes qw/time/;

use Atomic::Pipe;
use Test2::Harness2::Util::JSON qw/decode_json/;

# ---- basic write via pipe_write ----
subtest 'basic write via pipe_write' => sub {
    require Test2::Formatter::Stream2;

    my ($r, $w) = Atomic::Pipe->pair;
    $w->set_mixed_data_mode();
    $r->set_mixed_data_mode();

    my $fmt = Test2::Formatter::Stream2->new(pipe_write => $w);

    ok($fmt, "formatter constructed");
    is($fmt->hide_buffered, 0, "hide_buffered returns 0");

    my $before = time();
    $fmt->write(undef, 1, {assert => {pass => 1, details => 'ok'}});
    my $after = time();

    # Read from pipe
    my ($type, $data) = $r->get_line_burst_or_data();
    is($type, 'message', "got a message from pipe");
    ok($data, "data is not empty");

    my $event = decode_json($data);

    ok($event->{event_id},         "event_id present");
    ok($event->{stamp},            "stamp present");
    ok($event->{stamp} >= $before, "stamp is >= before");
    ok($event->{stamp} <= $after,  "stamp is <= after");
    is($event->{pid}, $$, "pid is current pid");
    ok(defined $event->{tid}, "tid is defined");
    is($event->{assert_count}, 1, "assert_count present and correct");

    my $fd = $event->{facet_data};
    ok($fd, "facet_data present");
    is($fd->{assert}{pass}, 1, "facet_data preserved");
};

# ---- stream_id increments ----
subtest 'stream_id increments' => sub {
    require Test2::Formatter::Stream2;

    my ($r, $w) = Atomic::Pipe->pair;
    $w->set_mixed_data_mode();
    $r->set_mixed_data_mode();

    my $fmt = Test2::Formatter::Stream2->new(pipe_write => $w);

    $fmt->write(undef, 1, {assert => {pass => 1}});
    $fmt->write(undef, 2, {assert => {pass => 1}});

    my ($type1, $data1) = $r->get_line_burst_or_data();
    my ($type2, $data2) = $r->get_line_burst_or_data();

    is($type1, 'message', "first message type");
    is($type2, 'message', "second message type");

    my $e1 = decode_json($data1);
    my $e2 = decode_json($data2);

    ok($e1->{stream_id}, "first has stream_id");
    ok($e2->{stream_id}, "second has stream_id");
    is($e2->{stream_id}, $e1->{stream_id} + 1, "stream_id increments");
};

# ---- no_numbers flag disables assert_count ----
subtest 'no_numbers suppresses assert_count' => sub {
    require Test2::Formatter::Stream2;

    my ($r, $w) = Atomic::Pipe->pair;
    $w->set_mixed_data_mode();
    $r->set_mixed_data_mode();

    my $fmt = Test2::Formatter::Stream2->new(pipe_write => $w, no_numbers => 1);

    $fmt->write(undef, 5, {assert => {pass => 1}});

    my ($type, $data) = $r->get_line_burst_or_data();
    is($type, 'message', "got message");

    my $event = decode_json($data);
    ok(!exists $event->{assert_count}, "assert_count absent when no_numbers set");
};

# ---- write with a Test2::Event object ----
subtest 'write with event object' => sub {
    require Test2::Formatter::Stream2;
    require Test2::Event::Ok;

    my ($r, $w) = Atomic::Pipe->pair;
    $w->set_mixed_data_mode();
    $r->set_mixed_data_mode();

    my $fmt = Test2::Formatter::Stream2->new(pipe_write => $w);

    my $event = Test2::Event::Ok->new(
        pass => 1,
        name => 'test event',
    );

    $fmt->write($event, 3);

    my ($type, $data) = $r->get_line_burst_or_data();
    is($type, 'message', "got message");

    my $decoded = decode_json($data);
    ok($decoded->{facet_data}, "facet_data present");
    is($decoded->{assert_count}, 3, "assert_count from num arg");
};

# ---- encoding change via control facet ----
subtest 'encoding change in control facet' => sub {
    require Test2::Formatter::Stream2;

    my ($r, $w) = Atomic::Pipe->pair;
    $w->set_mixed_data_mode();
    $r->set_mixed_data_mode();

    my $fmt = Test2::Formatter::Stream2->new(pipe_write => $w);

    # Should not die when encoding control facet is present
    ok(
        lives { $fmt->write(undef, 1, {control => {encoding => 'UTF-8'}}) },
        "encoding control event does not die"
    );

    my ($type, $data) = $r->get_line_burst_or_data();
    is($type, 'message', "got message");
};

# ---- auto-construct from STDOUT (pipe) ----
subtest 'auto-construct pipe_write from STDOUT' => sub {
    require Test2::Formatter::Stream2;

    my ($r, $w) = Atomic::Pipe->pair;

    # Redirect STDOUT to the pipe writer, just like the harness does
    open(my $saved_stdout, '>&', \*STDOUT) or die "Cannot save STDOUT: $!";
    open(STDOUT,           '>&', $w->wh)   or die "Cannot redirect STDOUT: $!";
    STDOUT->autoflush(1);

    my $fmt = Test2::Formatter::Stream2->new();

    ok($fmt,               "formatter constructed from STDOUT pipe");
    ok($fmt->{pipe_write}, "pipe_write set from STDOUT");

    $fmt->write(undef, 1, {assert => {pass => 1}});

    # Restore STDOUT before reading (so TAP output goes to the right place)
    open(STDOUT, '>&', $saved_stdout) or die "Cannot restore STDOUT: $!";
    STDOUT->autoflush(1);

    # Set reader to mixed data mode to read the message
    $r->set_mixed_data_mode();

    my ($type, $data) = $r->get_line_burst_or_data();
    is($type, 'message', "got message from STDOUT-constructed formatter");

    my $event = decode_json($data);
    ok($event->{event_id}, "event_id present");
};

done_testing;

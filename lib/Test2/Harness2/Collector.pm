package Test2::Harness2::Collector;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use POSIX qw/:sys_wait_h setpgid/;
use IO::Handle;
use IO::Select;
use Time::HiRes qw/sleep time/;
use Atomic::Pipe;
use Scope::Guard ();

use Test2::Harness2::Util::IPC qw/
    swap_io
    apply_atomic_pipe_compression
    atomic_pipe_compression_args
/;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Event;

use constant DEFAULT_KILL_TIMEOUT      => 5;
use constant DEFAULT_ORPHAN_TIMEOUT    => 30;
use constant DEFAULT_FLUSH_INTERVAL    => 0.25;
use constant FALLBACK_SELECT_TIMEOUT   => 1.0;

my @FORWARDED_SIGNALS = qw/TERM INT QUIT/;
my @IGNORED_SIGNALS   = qw/USR1 USR2 HUP PIPE/;

use Object::HashBase qw{
    <type
    <exec
    <run
    <parser
    <recorder
    <auditor
    <orphan_timeout
    <silence_timeout
    <lifetime_timeout
    <buffering
    <flush_interval
    -is_test_job
    -child_pid
    -out_pipe
    -err_pipe
    -pipes
    -by_fh
    -sel
    -start_time
    -last_activity
    -last_flush
    -wait_status
    -orphaned
    -timed_out
    -kill_state
    -buffer
};

sub start {
    my $class = shift;
    my $self  = $class->new(@_);
    return $self->run_collector;
}

sub init {
    my $self = shift;

    $self->{+TYPE}        //= 'test job';
    $self->{+IS_TEST_JOB} = ($self->{+TYPE} eq 'test job') ? 1 : 0;

    croak "exec or run must be supplied" unless $self->{+EXEC} || $self->{+RUN};
    croak "exec and run are mutually exclusive" if $self->{+EXEC} && $self->{+RUN};

    $self->{+ORPHAN_TIMEOUT}   //= DEFAULT_ORPHAN_TIMEOUT;
    $self->{+SILENCE_TIMEOUT}  //= 0;
    $self->{+LIFETIME_TIMEOUT} //= 0;
    $self->{+BUFFERING}        //= 1;
    $self->{+FLUSH_INTERVAL}   //= DEFAULT_FLUSH_INTERVAL;

    $self->{+RECORDER} = $self->_coerce_object($self->{+RECORDER}, 'recorder');
    $self->{+PARSER}   = $self->_coerce_object($self->{+PARSER},   'parser');
    $self->{+AUDITOR}  = $self->_coerce_auditor($self->{+AUDITOR}, $self->{+RECORDER});

    $self->{+ORPHANED}  = 0;
    $self->{+TIMED_OUT} = 0;

    return;
}

sub run_collector {
    my $self = shift;

    my ($out_r, $out_w) = Atomic::Pipe->pair(
        mixed_data_mode => 1,
        atomic_pipe_compression_args(),
    );
    my ($err_r, $err_w) = Atomic::Pipe->pair(
        mixed_data_mode => 1,
        atomic_pipe_compression_args(),
    );

    my $child = fork // die "fork: $!";

    if ($child == 0) {
        $out_r->close;
        $err_r->close;

        my $child_guard = Scope::Guard::guard(sub {
            print STDERR "Child process escaped collector scope!\n";
            POSIX::_exit(255);
        });

        my $ok  = eval { $self->_run_child($child_guard, $out_w, $err_w); 1 };
        my $err = $@;
        warn "Collector child died: $err\n" unless $ok;

        $child_guard->dismiss;
        POSIX::_exit($ok ? 0 : 255);
    }

    $out_w->close;
    $err_w->close;

    $self->{+CHILD_PID} = $child;
    $self->{+OUT_PIPE}  = $out_r;
    $self->{+ERR_PIPE}  = $err_r;

    $self->{+AUDITOR}->startup if $self->{+AUDITOR};

    my $ok  = eval { $self->_run_parent; 1 };
    my $err = $@;

    if (!$ok) {
        warn "Collector failed: $err\n";
        $self->_safe_kill;
    }

    my $status;
    if (defined $self->{+WAIT_STATUS}) {
        $status = $self->{+WAIT_STATUS};
    }
    else {
        waitpid($child, 0);
        $status = $?;
        $self->{+WAIT_STATUS} = $status;
    }

    $self->_finalize($ok);

    return $ok ? 0 : 255;
}

sub _coerce_object {
    my ($self, $thing, $label) = @_;
    return undef unless defined $thing;
    return $thing if blessed($thing);
    return $thing->new if !ref($thing);
    croak "'$label' must be a class name or an object, not a " . ref($thing);
}

sub _coerce_auditor {
    my ($self, $thing, $recorder) = @_;
    return undef unless defined $thing;
    if (blessed($thing)) {
        $thing->set_recorder($recorder) if $recorder && $thing->can('set_recorder');
        return $thing;
    }
    return $thing->new(recorder => $recorder) if !ref($thing);
    croak "'auditor' must be a class name or an object, not a " . ref($thing);
}

sub _run_child {
    my ($self, $guard, $out_w, $err_w) = @_;

    $out_w->blocking(1);
    $err_w->blocking(1);

    swap_io(\*STDOUT, $out_w->wh);
    swap_io(\*STDERR, $err_w->wh);

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    $ENV{T2_HARNESS2_PIPE_COUNT} = 2;

    setpgid(0, 0) if $self->{+IS_TEST_JOB};

    if (my $exec = $self->{+EXEC}) {
        CORE::exec(@$exec) or die "exec(@$exec) failed: $!";
    }

    $self->{+RUN}->($guard);
    return;
}

sub _run_parent {
    my $self = shift;

    my $out = $self->{+OUT_PIPE};
    my $err = $self->{+ERR_PIPE};

    apply_atomic_pipe_compression($out);
    apply_atomic_pipe_compression($err);

    local %SIG = %SIG;
    $self->_install_signal_handlers;

    my $sel = IO::Select->new;
    $sel->add($out->rh);
    $sel->add($err->rh);
    $self->{+SEL} = $sel;

    $self->{+PIPES} = {
        out => {stream => 'stdout', pipe => $out, eof => 0},
        err => {stream => 'stderr', pipe => $err, eof => 0},
    };
    $self->{+BY_FH} = {
        $out->rh => $self->{+PIPES}{out},
        $err->rh => $self->{+PIPES}{err},
    };

    $self->{+START_TIME}    = time;
    $self->{+LAST_ACTIVITY} = $self->{+START_TIME};
    $self->{+LAST_FLUSH}    = $self->{+START_TIME};
    $self->{+BUFFER}        = {seen => {}, saw_event => 0, stdout => [], stderr => []}
        if $self->{+BUFFERING};

    my $st = $self->_compute_select_timeouts;

    while ($sel->count) {
        my $timeout = defined $self->{+WAIT_STATUS} ? $st->{dead}
            : $self->{+KILL_STATE}                  ? $st->{dying}
            :                                         $st->{alive};
        my @ready = $sel->can_read($timeout);

        my $activity = 0;
        if (@ready) {
            for my $fh (@ready) {
                my $slot = $self->{+BY_FH}{$fh} or next;
                $slot->{pipe}->fill_buffer;
                $activity += $self->_drain_one_pipe($slot);
            }
        }
        else {
            $activity += $self->_drain_pipes;
        }

        $self->{+LAST_ACTIVITY} = time if $activity;

        $self->_periodic_flush;
        $self->_poll_child;
        $self->_check_test_job_timeouts;
        $self->_escalate_kill;

        last if $self->_check_orphan;
    }

    $self->_drain_pipes;
    $self->_flush_buffer;

    return;
}

sub _compute_select_timeouts {
    my $self = shift;

    my @flush;
    push @flush => $self->{+FLUSH_INTERVAL}
        if $self->{+BUFFER} && $self->{+FLUSH_INTERVAL};

    my @alive;
    if ($self->{+IS_TEST_JOB}) {
        push @alive => $self->{+SILENCE_TIMEOUT}  if $self->{+SILENCE_TIMEOUT};
        push @alive => $self->{+LIFETIME_TIMEOUT} if $self->{+LIFETIME_TIMEOUT};
    }

    my @dead;
    push @dead => $self->{+ORPHAN_TIMEOUT} if $self->{+ORPHAN_TIMEOUT};

    return {
        alive => _min_or_fallback(@flush, @alive),
        dying => _min_or_fallback(@flush, DEFAULT_KILL_TIMEOUT),
        dead  => _min_or_fallback(@flush, @dead),
    };
}

sub _min_or_fallback {
    return FALLBACK_SELECT_TIMEOUT unless @_;
    my $min = $_[0];
    for my $v (@_[1 .. $#_]) {
        $min = $v if $v < $min;
    }
    return $min;
}

sub _periodic_flush {
    my $self = shift;

    return unless $self->{+FLUSH_INTERVAL};
    my $buf = $self->{+BUFFER} or return;
    return if (time - $self->{+LAST_FLUSH}) < $self->{+FLUSH_INTERVAL};
    return unless @{$buf->{stdout}} || @{$buf->{stderr}};

    $self->_flush_buffer;
    return;
}

sub _poll_child {
    my $self = shift;
    return if defined $self->{+WAIT_STATUS};

    my $child = $self->{+CHILD_PID};
    my $r     = waitpid($child, WNOHANG);

    return if $r == 0;

    if ($r == $child) {
        $self->{+WAIT_STATUS} = $?;
    }
    else {
        # waitpid returned -1 (no such child) — already reaped or never
        # existed. On Windows pseudo-process pids are negative so this
        # branch is reached on both "child gone" and the pid==-1 corner
        # case; treat the child as done either way.
        $self->{+WAIT_STATUS} = 0;
    }
    return;
}

sub _check_test_job_timeouts {
    my $self = shift;

    return unless $self->{+IS_TEST_JOB};
    return if defined $self->{+WAIT_STATUS};
    return if $self->{+KILL_STATE};

    my $now = time;

    my $activity_delta = $now - $self->{+LAST_ACTIVITY};
    if ($self->{+SILENCE_TIMEOUT} && $activity_delta >= $self->{+SILENCE_TIMEOUT}) {
        $self->_trip_timeout(silence => $activity_delta);
        return;
    }

    my $lifetime_delta = $now - $self->{+START_TIME};
    if ($self->{+LIFETIME_TIMEOUT} && $lifetime_delta >= $self->{+LIFETIME_TIMEOUT}) {
        $self->_trip_timeout(lifetime => $lifetime_delta);
        return;
    }

    return;
}

sub _trip_timeout {
    my ($self, $kind, $delta) = @_;

    my $limit_attr = $kind eq 'silence' ? +SILENCE_TIMEOUT : +LIFETIME_TIMEOUT;

    $self->{+TIMED_OUT} = $kind;
    $self->_emit_timeout_event(
        kind  => $kind,
        limit => $self->{$limit_attr},
        delta => $delta,
    );

    kill 'TERM', $self->{+CHILD_PID};
    $self->{+KILL_STATE} = {sig => 'TERM', stamp => time};
    return;
}

sub _escalate_kill {
    my $self = shift;

    my $kill_state = $self->{+KILL_STATE} or return;
    return if defined $self->{+WAIT_STATUS};
    return unless $kill_state->{sig} eq 'TERM';
    return unless (time - $kill_state->{stamp}) >= DEFAULT_KILL_TIMEOUT;

    kill 'KILL', $self->{+CHILD_PID};
    $self->{+KILL_STATE} = {sig => 'KILL', stamp => time};
    return;
}

sub _check_orphan {
    my $self = shift;

    return 0 unless defined $self->{+WAIT_STATUS};
    return 0 unless $self->{+ORPHAN_TIMEOUT};
    return 0 unless $self->{+SEL}->count;
    return 0 unless (time - $self->{+LAST_ACTIVITY}) >= $self->{+ORPHAN_TIMEOUT};

    $self->{+ORPHANED} = 1;
    $self->_emit_orphan_event;
    return 1;
}

sub _drain_pipes {
    my $self  = shift;
    my $count = 0;
    for my $slot (values %{$self->{+PIPES}}) {
        next if $slot->{eof};
        $count += $self->_drain_one_pipe($slot);
    }
    return $count;
}

sub _drain_one_pipe {
    my ($self, $slot) = @_;

    my $pipe   = $slot->{pipe};
    my $stream = $slot->{stream};
    my $count  = 0;

    while (1) {
        my ($type, $data, %extra) = $pipe->get_line_burst_or_data;

        unless (defined $type) {
            if ($pipe->eof) {
                $self->{+SEL}->remove($pipe->rh);
                $slot->{eof} = 1;
            }
            return $count;
        }

        $count++;
        $self->_handle_pipe_record($stream, $type, $data, \%extra);
    }
}

sub _emit_timeout_event {
    my ($self, %args) = @_;

    my $kind  = $args{kind};
    my $limit = $args{limit};
    my $delta = sprintf('%.2f', $args{delta});

    my %reasons = (
        silence => "Test produced no output on STDOUT or STDERR for ${limit}s "
            . "(waited ${delta}s); the collector terminated it. "
            . "Increase or disable the silence timeout for slow tests.",
        lifetime => "Test exceeded its maximum lifetime of ${limit}s "
            . "(ran ${delta}s); the collector terminated it. "
            . "Increase or disable the lifetime timeout for long-running tests.",
    );

    my $event = Test2::Harness2::Event->new(
        facet_data => {
            harness_timeout => {
                kind          => $kind,
                limit_seconds => $limit + 0,
                delta_seconds => $args{delta} + 0,
                stamp         => time,
            },
            errors => [{
                tag          => 'TIMEOUT',
                fail         => 1,
                from_harness => 1,
                details      => "A $kind timeout occurred after ${delta}s; the collector is killing the test.",
            }],
            info => [{
                tag       => 'TIMEOUT',
                debug     => 1,
                important => 1,
                details   => $reasons{$kind},
            }],
        },
    );

    $self->_flush_buffer;
    $self->_dispatch_event($event);
    return;
}

sub _emit_orphan_event {
    my $self = shift;

    my $orphan_timeout = $self->{+ORPHAN_TIMEOUT};
    my $wait_status    = $self->{+WAIT_STATUS};

    my $details = sprintf(
        "Collected process exited (wait status %s) but pipes remained open; "
            . "collector waited %ss with no further output before giving up. "
            . "Likely a descendant process inherited the pipe and outlived its parent.",
        $wait_status, $orphan_timeout,
    );

    my $event = Test2::Harness2::Event->new(
        facet_data => {
            harness_orphan => {
                stamp         => time,
                quiet_seconds => $orphan_timeout,
                wait_status   => $wait_status,
            },
            info => [{
                tag     => 'ORPHAN',
                debug   => 1,
                details => $details,
            }],
        },
    );

    $self->_flush_buffer;
    $self->_dispatch_event($event);
    return;
}

sub _handle_pipe_record {
    my ($self, $stream, $type, $data, $extra) = @_;

    return $self->_handle_direct($stream, $type, $data, $extra)
        unless $self->{+BUFFER};

    my $buf   = $self->{+BUFFER};
    my $stamp = time;

    if ($type eq 'burst' || $type eq 'message') {
        my $decoded = eval { decode_json($data) };
        unless ($decoded) {
            warn "decode_json failed on $stream burst\n";
            return;
        }

        push @{$buf->{$stream}}, [$stamp, message => $decoded, $extra->{compressed}];

        my $event_id = (ref($decoded) eq 'HASH') ? $decoded->{event_id} : undef;
        return unless defined $event_id;

        $buf->{saw_event} = 1;

        # Each emission writes the full event on STDOUT and a tiny
        # {"event_id":"..."} sync marker on STDERR. Once we have seen
        # both halves of the pair, we can drain everything queued up to
        # (and including) that event in stream-order: stderr first
        # (raw STDERR lines, then the sync marker), then stdout (raw
        # STDOUT lines, then the event itself). Cross-pipe FIFO is not
        # otherwise guaranteed; the sync marker is what gives us a
        # consistent flush point.
        if (++$buf->{seen}{$event_id} >= 2) {
            $self->_flush_buffer(to => $event_id);
        }
        return;
    }

    if ($type eq 'line') {
        chomp $data;
        push @{$buf->{$stream}}, [$stamp, line => $data];

        # Before any structured event has been seen there is nothing
        # to pair raw lines against — flush immediately so they reach
        # the recorder in arrival order.
        $self->_flush_buffer unless $buf->{saw_event};
        return;
    }

    return;
}

sub _handle_direct {
    my ($self, $stream, $type, $data, $extra) = @_;

    my $parser = $self->{+PARSER};

    if ($type eq 'line') {
        chomp $data;
        my $event = $parser->parse_io(stream => $stream, line => $data);
        $self->_dispatch_event($event) if $event;
        return;
    }

    if ($type eq 'burst' || $type eq 'message') {
        # Buffering disabled — stderr sync markers have no pairing
        # role left, drop them.
        return if $stream eq 'stderr';

        my $decoded = eval { decode_json($data) };
        unless ($decoded) {
            warn "decode_json failed on $stream burst\n";
            return;
        }

        my $event = $parser->parse_io(
            stream => $stream,
            event  => $decoded,
            (defined $extra->{compressed} ? (compressed => $extra->{compressed}) : ()),
        );
        $self->_dispatch_event($event) if $event;
        return;
    }

    return;
}

sub _flush_buffer {
    my ($self, %params) = @_;

    my $buf    = $self->{+BUFFER} or return;
    my $parser = $self->{+PARSER};
    my $to     = $params{to};

    for my $stream (qw/stderr stdout/) {
        my $queue = $buf->{$stream};
        while (my $entry = shift @$queue) {
            my ($stamp, $kind, $val, $compressed) = @$entry;

            if ($kind eq 'message') {
                if ($stream eq 'stdout') {
                    my $event = $parser->parse_io(
                        stream => $stream,
                        event  => $val,
                        (defined $compressed ? (compressed => $compressed) : ()),
                    );
                    $self->_dispatch_event($event) if $event;
                }

                if (ref($val) eq 'HASH' && defined(my $eid = $val->{event_id})) {
                    delete $buf->{seen}{$eid};
                    last if defined($to) && $eid eq $to;
                }
            }
            else {
                my $event = $parser->parse_io(stream => $stream, line => $val);
                $self->_dispatch_event($event) if $event;
            }
        }
    }

    $self->{+LAST_FLUSH} = time;
    return;
}

sub _dispatch_event {
    my ($self, $event) = @_;

    my $auditor = $self->{+AUDITOR};
    my $rec     = $self->{+RECORDER};

    my @events = $auditor ? $auditor->audit_event($event) : ($event);
    for my $e (@events) {
        my $ok = eval { $rec->record_event($e); 1 };
        warn "record_event failed: $@\n" unless $ok;
    }
    return;
}

sub _install_signal_handlers {
    my $self  = shift;
    my $child = $self->{+CHILD_PID};
    $SIG{$_} = 'IGNORE' for @IGNORED_SIGNALS;
    for my $sig (@FORWARDED_SIGNALS) {
        $SIG{$sig} = sub { kill $sig, $child };
    }
    return;
}

sub _safe_kill {
    my $self  = shift;
    my $child = $self->{+CHILD_PID} or return;
    kill 'TERM', $child;
    my $deadline = time + DEFAULT_KILL_TIMEOUT;
    while (time < $deadline) {
        $self->_poll_child;
        return if defined $self->{+WAIT_STATUS};
        sleep 0.05;
    }
    kill 'KILL', $child;
    return;
}

sub _finalize {
    my ($self, $ok) = @_;

    my $rec       = $self->{+RECORDER};
    my $auditor   = $self->{+AUDITOR};
    my $status    = $self->{+WAIT_STATUS};
    my $orphaned  = $self->{+ORPHANED}  ? 1 : 0;
    my $timed_out = $self->{+TIMED_OUT} || 0;

    if ($rec) {
        my $ok = eval {
            $rec->record_exit($status, {
                orphaned  => $orphaned,
                timed_out => $timed_out,
            });
            1;
        };
        warn "record_exit failed: $@\n" unless $ok;
    }

    if ($auditor) {
        my $exit_event = Test2::Harness2::Event->new(
            facet_data => {harness_process_exit => {all => $status}},
        );
        my @final = eval { $auditor->audit_event($exit_event) };
        warn "auditor exit-event failed: $@\n" if $@;

        for my $e (@final) {
            my $ok = eval { $rec->record_event($e); 1 } if $rec;
            warn "record_event (exit-final) failed: $@\n" unless $ok;
        }

        my $ok = eval { $auditor->shutdown; 1 };
        warn "auditor shutdown failed: $@\n" unless $ok;
    }

    if ($rec) {
        my $ok = eval { $rec->finalize; 1 };
        warn "recorder finalize failed: $@\n" unless $ok;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector - Fork a child process and feed its events
through a parser / auditor / recorder pipeline.

=head1 DESCRIPTION

Entry point for the collector subsystem. C<start> forks a single child,
wires the child's STDOUT and STDERR to mixed-mode L<Atomic::Pipe>s, and
in the collector parent drives the event pipeline:

    bytes  ->  parser  ->  optional auditor  ->  recorder

The parser turns raw stream lines and pre-decoded JSON message bursts
into L<Test2::Harness2::Event> objects. The auditor (only for test-job
collectors) tracks pass / fail state, emits synthetic events for
subtest announcements and TAP recovery, and drives state transitions
through the recorder. The recorder is the only object in the pipeline
allowed to own external state (files or a database handle).

The collector returns C<0> when the pipeline finished cleanly,
regardless of the collected process's own exit status. The collected
process's pass/fail signal lives in the event stream (auditor +
recorder), not in the collector's return value. The collector returns
C<255> only when it itself failed internally before the pipeline could
finish.

=head1 SYNOPSIS

    use Test2::Harness2::Collector;
    use Test2::Harness2::Collector::Parser::TAPParser;
    use Test2::Harness2::Collector::Auditor::Test;
    use Test2::Harness2::Collector::Recorder::Files;

    my $r = Test2::Harness2::Collector::Recorder::Files->new(dir => $path);

    my $exit = Test2::Harness2::Collector->start(
        type     => 'test job',
        exec     => [$^X, '-Ilib', 't/foo.t'],
        parser   => Test2::Harness2::Collector::Parser::TAPParser->new,
        auditor  => Test2::Harness2::Collector::Auditor::Test->new(recorder => $r),
        recorder => $r,
    );

The class is a normal L<Object::HashBase> object. C<start> is a thin
convenience that constructs a collector via C<new> and then calls
C<run_collector> on it. Callers that want to inspect the collector
after the run (state flags, captured wait status, etc.) can build
the object themselves and drive it directly.

=head1 PUBLIC METHODS

=over 4

=item $exit = Test2::Harness2::Collector->start(%args)

Convenience constructor + driver: C<< $class->new(%args)->run_collector >>.
Returns C<0> on a clean run (the collected process's own exit status
is recorded into the event stream, not returned here) or C<255> on
collector-side failure.

=item $self = Test2::Harness2::Collector->new(%args)

Standard L<Object::HashBase> constructor. Validates C<exec> /
C<run>, coerces class-name C<parser> / C<recorder> / C<auditor>
arguments into instances, and applies attribute defaults. Does not
fork; the child only forks on C<run_collector>.

=item $exit = $self->run_collector

Fork once, run the requested command (or callback) in the child, and
run the event pipeline in the collector parent until both pipes hit
EOF and the child has been reaped (or one of the configured timeouts
fires). Returns the same exit code semantics as C<start>. May only
be called once per collector instance.

Named arguments:

=over 4

=item type => 'test job' | 'service' | ...

What kind of process is being collected. C<'test job'> (the default)
puts the child in a fresh process group via C<setpgid(0, 0)> so the
test cannot signal the collector / launcher tree.

=item exec => \@argv

A command + args list to C<exec> in the child.

=item run => \&callback

A code reference to invoke in the child instead of C<exec>. The child
exits C<0> when the callback returns. Mutually exclusive with C<exec>.

=item parser => $instance_or_class

L<Test2::Harness2::Collector::Role::Parser> implementer. A bare class
name is constructed with no arguments.

=item auditor => $instance_or_class

Optional L<Test2::Harness2::Collector::Role::Auditor> implementer. A
bare class name is constructed with C<< recorder => $recorder >> so
state transitions reach the recorder.

=item recorder => $instance_or_class

L<Test2::Harness2::Collector::Role::Recorder> implementer. A bare class
name is constructed with no arguments.

=item orphan_timeout => $seconds

How long (in seconds) the collector will keep reading from the
collected process's pipes after the collected process itself has
exited, before declaring the pipes "orphaned" and giving up. A test or
service may fork descendants that inherit the pipes and outlive their
parent; those descendants would otherwise hold the pipes open forever.

When the timeout expires after the child has been reaped and no
further output has arrived, the collector emits a synthetic
C<harness_orphan> event into the stream, flags the collector run as
orphaned through C<record_exit>, and exits. The condition is treated
as a warning, not a failure: the collector's exit code still mirrors
the collected process's wait status.

Default: C<30>. C<0> disables the check (the collector then waits
indefinitely for both pipes to hit EOF).

=item silence_timeout => $seconds

Test-job only. Maximum interval (in seconds) the collector will
tolerate with no output on either pipe while the collected process
is still running. When the gap reaches the limit, the collector
emits a synthetic C<TIMEOUT> error event into the stream (which the
auditor turns into a failure), sends C<SIGTERM> to the child, and
escalates to C<SIGKILL> after the standard kill-grace if the child
does not exit. Service collectors ignore the setting.

Default: C<0> (disabled). Callers (the future yath CLI; per-test
directives once a metadata layer exists) supply their own default.

=item lifetime_timeout => $seconds

Test-job only. Maximum total runtime the collector will allow,
regardless of whether the test is still producing output. Same
event / kill behavior as C<silence_timeout> once it fires. Service
collectors ignore the setting.

Default: C<0> (disabled). Useful as an outer guard for tests that
livelock while still printing.

=item buffering => $bool

When true (the default), the collector buffers per-stream entries
and uses the STDOUT-event / STDERR-sync-marker pairing described in
C<ARCHITECTURE.md> §5.3 to keep raw STDOUT / STDERR output ordered
correctly against the structured events that bracket it. When
false, every record dispatches immediately; STDERR sync markers are
dropped (they have no pairing role left), and raw output appears in
strict pipe-arrival order with no cross-pipe re-ordering. Disable
when the consumer cares more about live-tail latency than about
interleaving consistency.

Default: C<1> (buffering on).

=item flush_interval => $seconds

Maximum time the collector will hold buffered records before
forcing a flush, even when no event-pair has arrived to trigger a
natural sync flush. Prevents raw output from being hidden during
long pauses between structured events (a test that prints raw
diagnostics for a long time between assertions, etc.). Ignored when
C<buffering> is false.

Default: C<0.25> (250 ms). C<0> disables the periodic flush;
buffered records then wait indefinitely for an event-pair.

=back

=back

=head1 PRIVATE METHODS

=over 4

=item $self->_run_child($out_w, $err_w)

Child-side bootstrap: replace STDOUT / STDERR with the mixed-mode pipe
writers, set C<T2_HARNESS2_PIPE_COUNT=2> so
L<Test2::Formatter::Stream2> and L<Test2::Harness2::Util::EventEmitter>
recognise they are inside a collector, place test-job collected
processes in a fresh process group, and either C<exec> the requested
command or invoke the callback.

=item $self->_run_parent

Parent-side IO loop: select on both pipe read ends, decode message
bursts to events through the parser, optionally route through the
auditor, write through the recorder. Continues until both pipes hit
EOF, until one of the configured timeouts fires, or until the orphan
watchdog gives up. Drives C<_poll_child>,
C<_check_test_job_timeouts>, C<_escalate_kill>, and C<_check_orphan>
once per iteration.

=item $self->_finalize($ok)

Tail of the parent path: record the wait-status on the recorder
along with the C<orphaned> / C<timed_out> flags, synthesize the
C<harness_process_exit> event through the auditor so the auditor's
final-state hash carries the exit code, run the auditor's
C<shutdown> hook, and finalize the recorder.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

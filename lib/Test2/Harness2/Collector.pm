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

use Test2::Harness2::Util::IPC qw/
    swap_io
    apply_atomic_pipe_compression
    atomic_pipe_compression_args
/;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Event;

use constant DEFAULT_KILL_TIMEOUT   => 5;
use constant DEFAULT_ORPHAN_TIMEOUT => 30;
use constant SELECT_TIMEOUT         => 0.1;

my @FORWARDED_SIGNALS = qw/TERM INT QUIT/;
my @IGNORED_SIGNALS   = qw/USR1 USR2 HUP PIPE/;

sub start {
    my $class = shift;
    my %args  = @_;

    my $type     = $args{type} // 'test job';
    my $exec     = $args{exec};
    my $run      = $args{run};
    my $parser   = $class->_coerce_object($args{parser},   'parser');
    my $recorder = $class->_coerce_object($args{recorder}, 'recorder');
    my $auditor  = $class->_coerce_auditor($args{auditor}, $recorder);

    my $orphan_timeout = exists $args{orphan_timeout}
        ? $args{orphan_timeout}
        : DEFAULT_ORPHAN_TIMEOUT;

    croak "exec or run must be supplied" unless $exec || $run;
    croak "exec and run are mutually exclusive" if $exec && $run;

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
        $class->_run_child($out_w, $err_w, $type, $exec, $run);
        exit 255;
    }

    $out_w->close;
    $err_w->close;

    $auditor->startup if $auditor;

    my %parent_out;
    my $ok = eval {
        %parent_out = $class->_run_parent(
            child_pid      => $child,
            out_pipe       => $out_r,
            err_pipe       => $err_r,
            parser         => $parser,
            auditor        => $auditor,
            recorder       => $recorder,
            type           => $type,
            orphan_timeout => $orphan_timeout,
        );
        1;
    };
    my $err = $@;

    if (!$ok) {
        warn "Collector failed: $err\n";
        $class->_safe_kill($child);
    }

    my $status;
    if (defined $parent_out{wait_status}) {
        $status = $parent_out{wait_status};
    }
    else {
        waitpid($child, 0);
        $status = $?;
    }

    $class->_finalize(
        wait_status => $status,
        recorder    => $recorder,
        auditor     => $auditor,
        ok          => $ok,
        orphaned    => $parent_out{orphaned} ? 1 : 0,
    );

    return $ok ? ($status >> 8) : 255;
}

sub _coerce_object {
    my ($class, $thing, $label) = @_;
    return undef unless defined $thing;
    return $thing if blessed($thing);
    return $thing->new if !ref($thing);
    croak "'$label' must be a class name or an object, not a " . ref($thing);
}

sub _coerce_auditor {
    my ($class, $thing, $recorder) = @_;
    return undef unless defined $thing;
    return $thing if blessed($thing);
    return $thing->new(recorder => $recorder) if !ref($thing);
    croak "'auditor' must be a class name or an object, not a " . ref($thing);
}

sub _run_child {
    my ($class, $out_w, $err_w, $type, $exec, $run) = @_;

    $out_w->blocking(1);
    $err_w->blocking(1);

    swap_io(\*STDOUT, $out_w->wh);
    swap_io(\*STDERR, $err_w->wh);

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    $ENV{T2_HARNESS2_PIPE_COUNT} = 2;

    setpgid(0, 0) if $type eq 'test job';

    if ($exec) {
        exec(@$exec) or die "exec(@$exec) failed: $!";
    }

    $run->();
    exit 0;
}

sub _run_parent {
    my ($class, %args) = @_;

    my $child          = $args{child_pid};
    my $out            = $args{out_pipe};
    my $err            = $args{err_pipe};
    my $parser         = $args{parser};
    my $auditor        = $args{auditor};
    my $rec            = $args{recorder};
    my $orphan_timeout = $args{orphan_timeout};

    apply_atomic_pipe_compression($out);
    apply_atomic_pipe_compression($err);

    local %SIG = %SIG;
    $class->_install_signal_handlers($child);

    my $sel = IO::Select->new;
    $sel->add($out->rh);
    $sel->add($err->rh);

    my %pipes = (
        out => {stream => 'stdout', pipe => $out, eof => 0},
        err => {stream => 'stderr', pipe => $err, eof => 0},
    );
    my %by_fh = ($out->rh => $pipes{out}, $err->rh => $pipes{err});

    my $wait_status;
    my $last_activity = time;
    my $orphaned      = 0;

    while ($sel->count) {
        my @ready = $sel->can_read(SELECT_TIMEOUT);

        my $activity = 0;
        if (@ready) {
            for my $fh (@ready) {
                my $slot = $by_fh{$fh} or next;
                $slot->{pipe}->fill_buffer;
                $activity += $class->_drain_one_pipe($slot, $sel, $parser, $auditor, $rec);
            }
        }
        else {
            $activity += $class->_drain_pipes(\%pipes, $sel, $parser, $auditor, $rec);
        }

        $last_activity = time if $activity;

        unless (defined $wait_status) {
            my $r = waitpid($child, WNOHANG);
            if ($r > 0) {
                $wait_status = $?;
            }
            elsif ($r == -1) {
                $wait_status = 0;
            }
        }

        if (defined $wait_status && $orphan_timeout && $sel->count) {
            if (time - $last_activity >= $orphan_timeout) {
                $orphaned = 1;
                $class->_emit_orphan_event(
                    orphan_timeout => $orphan_timeout,
                    wait_status    => $wait_status,
                    auditor        => $auditor,
                    rec            => $rec,
                );
                last;
            }
        }
    }

    $class->_drain_pipes(\%pipes, $sel, $parser, $auditor, $rec);

    return (wait_status => $wait_status, orphaned => $orphaned);
}

sub _drain_pipes {
    my ($class, $pipes, $sel, $parser, $auditor, $rec) = @_;
    my $count = 0;
    for my $slot (values %$pipes) {
        next if $slot->{eof};
        $count += $class->_drain_one_pipe($slot, $sel, $parser, $auditor, $rec);
    }
    return $count;
}

sub _drain_one_pipe {
    my ($class, $slot, $sel, $parser, $auditor, $rec) = @_;

    my $pipe   = $slot->{pipe};
    my $stream = $slot->{stream};
    my $count  = 0;

    while (1) {
        my ($type, $data, %extra) = $pipe->get_line_burst_or_data;

        unless (defined $type) {
            if ($pipe->eof) {
                $sel->remove($pipe->rh);
                $slot->{eof} = 1;
            }
            return $count;
        }

        $count++;
        $class->_handle_pipe_record($stream, $type, $data, \%extra, $parser, $auditor, $rec);
    }
}

sub _emit_orphan_event {
    my ($class, %args) = @_;

    my $orphan_timeout = $args{orphan_timeout};
    my $wait_status    = $args{wait_status};
    my $auditor        = $args{auditor};
    my $rec            = $args{rec};

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

    $class->_dispatch_event($event, $auditor, $rec);
    return;
}

sub _handle_pipe_record {
    my ($class, $stream, $type, $data, $extra, $parser, $auditor, $rec) = @_;

    if ($type eq 'line') {
        chomp $data;
        my $event = $parser->parse_io(stream => $stream, line => $data) or return;
        $class->_dispatch_event($event, $auditor, $rec);
        return;
    }

    if ($type eq 'burst' || $type eq 'message') {
        if ($stream eq 'stderr') {
            return;
        }
        my $decoded = eval { decode_json($data) };
        return unless $decoded;

        my $event = $parser->parse_io(
            stream => $stream,
            event  => $decoded,
            (defined $extra->{compressed} ? (compressed => $extra->{compressed}) : ()),
        ) or return;

        $class->_dispatch_event($event, $auditor, $rec);
        return;
    }

    return;
}

sub _dispatch_event {
    my ($class, $event, $auditor, $rec) = @_;

    my @events = $auditor ? $auditor->audit_event($event) : ($event);
    for my $e (@events) {
        my $ok = eval { $rec->record_event($e); 1 };
        warn "record_event failed: $@\n" unless $ok;
    }
    return;
}

sub _install_signal_handlers {
    my ($class, $child) = @_;
    $SIG{$_} = 'IGNORE' for @IGNORED_SIGNALS;
    for my $sig (@FORWARDED_SIGNALS) {
        $SIG{$sig} = sub { kill $sig, $child };
    }
    return;
}

sub _safe_kill {
    my ($class, $child) = @_;
    return unless $child;
    kill 'TERM', $child;
    my $deadline = time + DEFAULT_KILL_TIMEOUT;
    while (time < $deadline) {
        my $done = waitpid($child, WNOHANG);
        return if $done;
        sleep 0.05;
    }
    kill 'KILL', $child;
    return;
}

sub _finalize {
    my ($class, %args) = @_;
    my $rec      = $args{recorder};
    my $auditor  = $args{auditor};
    my $status   = $args{wait_status};
    my $orphaned = $args{orphaned} ? 1 : 0;

    if ($rec) {
        my $ok = eval { $rec->record_exit($status, {orphaned => $orphaned}); 1 };
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

The collector exits with the child's decoded exit code on success, or
C<255> if it itself failed before the pipeline finished.

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

=head1 PUBLIC METHODS

=over 4

=item $exit = Test2::Harness2::Collector->start(%args)

Fork once, run the requested command (or callback) in the child, and run
the event pipeline in the collector parent until both pipes hit EOF and
the child has been reaped. Returns the decoded exit code of the collected
process on success, C<255> on collector-side failure.

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

=back

=back

=head1 PRIVATE METHODS

=over 4

=item $class->_run_child($out_w, $err_w, $type, $exec, $run)

Child-side bootstrap: replace STDOUT / STDERR with the mixed-mode pipe
writers, set C<T2_HARNESS2_PIPE_COUNT=2> so
L<Test2::Formatter::Stream2> and L<Test2::Harness2::Util::EventEmitter>
recognise they are inside a collector, place test-job collected
processes in a fresh process group, and either C<exec> the requested
command or invoke the callback.

=item $class->_run_parent(%args)

Parent-side IO loop: select on both pipe read ends, decode message
bursts to events through the parser, optionally route through the
auditor, write through the recorder. Continues until both pipes hit
EOF.

=item $class->_finalize(%args)

Tail of the parent path: record the wait-status on the recorder,
synthesize the C<harness_process_exit> event through the auditor so the
auditor's final-state hash carries the exit code, run the auditor's
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

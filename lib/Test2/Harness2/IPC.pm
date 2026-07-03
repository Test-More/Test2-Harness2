package Test2::Harness2::IPC;
use strict;
use warnings;

our $VERSION = '2.000000';

use POSIX;

use Config qw/%Config/;
use Carp qw/croak confess/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util qw/mono_time/;
use Test2::Harness2::Util::IPC qw/run_cmd USE_P_GROUPS/;

use Test2::Harness2::IPC::Process;

BEGIN {
    my %SIG_MAP;
    my @SIGNAMES = split /\s+/, $Config{sig_name};
    my @SIGNUMS  = split /\s+/, $Config{sig_num};
    while (@SIGNAMES) {
        $SIG_MAP{shift(@SIGNAMES)} = shift @SIGNUMS;
    }

    *SIG_MAP = sub() { \%SIG_MAP };

    # Debug gate for the "should never happen" reaper fallbacks. These are
    # benign guards (a tracked process that vanished without being reaped here,
    # or an unexpectedly-broken wait loop); their warns are noise on the happy
    # path, so they only print when T2_HARNESS_IPC_DEBUG is set.
    my $debug = $ENV{T2_HARNESS_IPC_DEBUG} ? 1 : 0;
    *IPC_DEBUG = sub() { $debug };
}

use Test2::Harness2::Util::HashBase qw{
    <pid
    <handlers
    <procs
    <waiting
    <wait_time
    <started
    <sig_count

    <signal

    <post_exit_timeout
    +last_timeout_check
    +timeout_signaled
};

sub init {
    my $self = shift;

    $self->{+PID} = $$;

    $self->{+PROCS} //= {};

    $self->{+WAIT_TIME} = 0.02 unless defined $self->{+WAIT_TIME};

    $self->{+HANDLERS} //= {};
    $self->{+HANDLERS}->{CHLD} //= sub { 1 };

    $self->{+SIG_COUNT} //= 0;
}

sub start {
    my $self = shift;

    return if $self->{+STARTED};
    $self->{+STARTED} = 1;

    $self->check_for_fork();

    for my $sig (qw/INT HUP TERM CHLD/) {
        croak "Signal '$sig' was already set by something else"
            if defined $SIG{$sig}
            && $SIG{$sig} ne 'IGNORE'
            && $SIG{$sig} ne 'DEFAULT';
        $SIG{$sig} = sub { $self->handle_sig($sig) };
    }
}

sub stop {
    my $self = shift;

    $self->check_for_fork;

    # Escalating shutdown of tracked children (hoisted from Runner/Preload::Host,
    # ticket #67): TERM the tracked process group (using SIGNAL if a shutdown signal
    # was captured), give them a short window, then KILL any holdouts. A consumer's
    # own SIGNAL field selects the initial signal; the base has none set, so it TERMs.
    if (keys %{$self->{+PROCS}}) {
        print "$$ $0 Sending all child processes the TERM signal...\n";
        $self->killall($self->{+SIGNAL} // 'TERM');
        $self->wait(all => 1, timeout => 5);
    }

    # Time to get serious
    if (keys %{$self->{+PROCS}}) {
        local $?;
        print STDERR "$$ $0 Some child processes are refusing to exit, sending KILL signal...\n";
        print("$$ $0 == $_ " . waitpid($_, WNOHANG) . "\n") for keys %{$self->{+PROCS}};
        $self->killall('KILL');
    }

    $self->wait(all => 1);

    delete $SIG{$_} for qw/INT HUP TERM CHLD/;

    $self->{+STARTED} = 0;
}

# The die-message prefix used by handle_sig, so the "<prefix> caught SIG..." text
# stays byte-identical per consumer. Overridden by Runner ('Runner') and
# Preload::Host ('Preload::Host'); the base uses the concrete class name.
sub sig_prefix { ref($_[0]) }

sub handle_sig {
    my $self = shift;
    my ($sig) = @_;

    # Already winding down (a shutdown signal was captured): swallow repeats so a
    # second signal does not re-die mid-cleanup. Kept FIRST as in both former
    # consumers.
    return if $self->{+SIGNAL};

    return $self->{+HANDLERS}->{$sig}->($sig) if $self->{+HANDLERS}->{$sig};

    $self->{+SIGNAL} = $sig;
    die $self->sig_prefix . " caught SIG$sig. Attempting to shut down cleanly...\n";
}

sub killall {
    my $self = shift;
    my ($sig) = @_;
    $sig //= 'TERM';

    $self->check_for_fork();

    if (USE_P_GROUPS) {
        kill($sig, map { -$_ } keys %{$self->{+PROCS}});
    }
    else {
        kill($sig, keys %{$self->{+PROCS}});
    }
}

# Fallback escalation for a wedged collector PARENT (hoisted from Runner/Preload::Host,
# ticket #67). Called every loop of wait(). Requires the consumer to provide a
# `settings` accessor (Runner and Preload::Host both do; no other consumer exists).
sub check_timeouts {
    my $self = shift;

    return unless $self->settings->runner->use_timeout;

    my $now = time;

    # Check only once per second, that is as granular as we get. Also the check is not cheep.
    return if $self->{+LAST_TIMEOUT_CHECK} && $now < (1 + $self->{+LAST_TIMEOUT_CHECK});

    # The per-test silence and lifetime timeouts are now enforced by the
    # Test2-Collector collector parent itself (via collect(silence_timeout =>
    # ..., lifetime_timeout => ...)): it kills the test child's process group,
    # records the timeout in events.jsonl.zst, and exits. The runner no longer
    # tracks per-job output activity or writes event_timeout/post_exit_timeout
    # marker files.
    #
    # What remains here is a fallback for a collector PARENT that should have
    # exited but has not: once a job process has been reaped (it is in WAITING)
    # we give it a grace window, then escalate TERM -> KILL so a wedged
    # collector cannot hang the run.
    my $grace = $self->{+POST_EXIT_TIMEOUT} || 60;

    my $signaled = $self->{+TIMEOUT_SIGNALED} //= {};

    # Drop entries for pids that are no longer live, so a future job that reuses
    # a pid does not inherit a stale "already TERMed, escalate to KILL" flag.
    delete $signaled->{$_} for grep { !$self->{+PROCS}->{$_} } keys %$signaled;

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job = $self->{+PROCS}->{$pid};
        next unless $job->isa('Test2::Harness2::Runner::Job');

        my $waiting = $self->{+WAITING}->{$pid} or next;
        my $since   = $waiting->[1] // $now;
        next unless ($now - $since) > $grace;

        my $kill = $signaled->{$pid}++;

        my $sigmap = $self->SIG_MAP;
        my $sig    = $kill ? $sigmap->{'KILL'} : $sigmap->{'TERM'};
        $sig = "-$sig" if $self->USE_P_GROUPS;

        print STDERR "$$ $0 " . $job->file . " collector process-group did not fully exit after the collector was reaped, sending " . ($kill ? 'SIGKILL' : 'SIGTERM') . " to $pid...\n";

        kill($sig, $pid);
    }

    $self->{+LAST_TIMEOUT_CHECK} = time;
}

sub check_for_fork {
    my $self = shift;

    return 0 if $self->{+PID} == $$;

    $self->{+PROCS}   = {};
    $self->{+WAITING} = {};
    $self->{+PID}     = $$;

    return 1;
}

sub _bring_out_yer_dead {
    my $self = shift;

    my $procs   = $self->{+PROCS}   //= {};
    my $waiting = $self->{+WAITING} //= {};

    local $?;

    # Wait on any/all pids
    my $found = 0;
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        my $exit = $?;
        # A pid we are not monitoring is a child forked by a plugin or 3rd-party
        # module that we happened to reap here; that is benign, just skip it.
        next unless $procs->{$pid};
        $found++;
        $waiting->{$pid} = [$exit, time()];
    }

    return $found;
}

sub _check_if_dead_yet {
    my $self = shift;

    my $procs   = $self->{+PROCS}   //= {};
    my $waiting = $self->{+WAITING} //= {};

    my $found = 0;
    for my $pid (keys %$waiting) {
        next if USE_P_GROUPS && kill(0, -$pid);
        $found++;
        my $args = delete $waiting->{$pid};
        my $proc = delete $procs->{$pid};
        $self->set_proc_exit($proc, @$args);
    }

    return $found;
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, @args) = @_;
    $proc->set_exit($self, @args);
}

sub _ex_parrots {
    my $self = shift;

    my $procs   = $self->{+PROCS}   //= {};
    my $waiting = $self->{+WAITING} //= {};

    my $found = 0;
    for my $pid (keys %$procs) {
        next if $waiting->{$pid};
        next if kill(0, $pid);
        $found++;
        warn "Process $pid vanished!" if IPC_DEBUG;
        $waiting->{$pid} = [-1, time()];
    }

    return $found;
}

sub wait {
    my $self   = shift;
    my %params = @_;

    $self->check_for_fork();

    my $sig_count = $self->{+SIG_COUNT};

    my $procs   = $self->{+PROCS}   //= {};
    my $waiting = $self->{+WAITING} //= {};

    return 0 unless keys(%$procs) || keys(%$waiting);

    # wait() timeout window is a pure interval; monotonic so a wall/NTP step
    # cannot warp it. Pairs with the compare in _wait_done. (#134 finding 104)
    my $start = mono_time;

    my $count = 0;
    my $found = 0;
    while (1) {
        $self->check_timeouts;

        $found += $self->_bring_out_yer_dead();
        $found += $self->_check_if_dead_yet();

        return $found if $self->_wait_done($start, \%params);

        # This is expensive, so only do it if we are gonna end up waiting
        # anyway If we do find anything here do not bother waiting.
        next if $self->_ex_parrots();

        # Break the loop if we had a signal come in since starting
        last if $self->{+SIG_COUNT} > $sig_count;

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    warn "We escaped the wait cycle" if IPC_DEBUG;
    return $found;
}

sub _wait_done {
    my $self = shift;
    my ($start, $params) = @_;

    my $all = keys(%{$self->{+PROCS}});
    return 1 unless $all;

    return 1 if $params->{timeout} && mono_time - $start >= $params->{timeout};    # pairs with wait()'s mono_time $start (#134 finding 104)

    return 0 if $all && $params->{all};

    return 1;
}

sub watch_pid {
    my $self = shift;
    my ($pid) = @_;

    my $proc = Test2::Harness2::IPC::Process->new(pid => $pid);

    return $self->watch($proc);
}

sub watch {
    my $self = shift;
    my ($proc) = @_;

    $self->check_for_fork();

    my $pid = $proc->pid or confess "Process has no pid";
    $pid = abs($pid) if USE_P_GROUPS;

    croak "Already watching pid $pid" if exists $self->{+PROCS}->{$pid};

    $self->{+PROCS}->{$pid} = $proc;
}

sub spawn {
    my $self = shift;
    my ($proc, $params);
    if (@_ == 1) {
        $proc = shift(@_);
        $params = $proc->spawn_params;
    }
    else {
        $params = {@_};
        my $class = $params->{process_class} // 'Test2::Harness2::IPC::Process';
        $proc = $class->new();
    }

    croak "No 'command' specified" unless $params->{command};

    my $caller1 = [caller()];
    my $caller2 = [caller(1)];

    my $env = $params->{env_vars} // {};

    $self->check_for_fork();

    my $pid = run_cmd(env => $env, caller1 => $caller1, caller2 => $caller2, %$params);
    $proc->set_pid($pid);

    $self->watch($proc);
    return $proc;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::IPC - Base class for modules that control child processes.

=head1 DESCRIPTION

This module is the base class for all parts of L<Test2::Harness2> that have to
do process management.

=head1 ATTRIBUTES

=over 4

=item $pid = $ipc->pid

The root PID of the IPC object.

=item $hashref = $ipc->handlers

Custom signal handlers specific to the IPC object.

=item $hashref = $ipc->procs

Hashref of C<< $pid => $proc >> where $proc is an instance of
L<Test2::Harness2::IPC::Process>.

=item $hashref = $ipc->waiting

Hashref of processes that have finished, but have not been handled yet.

This is an implementation detail you should not rely on.

=item $float = $ipc->wait_time

How long to sleep between loops when in a wait cycle.

=item $bool = $ipc->started

True if the IPC process has started.

=item $ipc->sig_count

Implementation detail, used to break wait loops when signals are received.

=back

=head1 METHODS

=over 4

=item $ipc->start

Start the IPC management (Insert signal handlers).

=item $ipc->stop

Stop the IPC management (Remove signal handlers).

=item $ipc->handle_sig($sig)

Handle the specified signal. If a shutdown signal has already been captured
(C<< $ipc->signal >> is set) it is swallowed. Otherwise a registered handler in
C<< $ipc->handlers >> is dispatched; failing that the signal is recorded in
C<< $ipc->signal >> and a C<die> is thrown (prefixed by C<< $ipc->sig_prefix >>)
so the C<wait> loop unwinds into a clean shutdown.

=item $prefix = $ipc->sig_prefix

The prefix used in C<handle_sig>'s "<prefix> caught SIG..." message. Defaults to
the object's class name; subclasses may override it to keep the message text
stable.

=item $ipc->killall()

=item $ipc->killall($sig)

Kill all tracked child process with the given signal. C<TERM> is used if no
signal is specified.

This will not wait on the processes, you must call C<< $ipc->wait() >>.

=item $ipc->check_timeouts

Called every loop of C<< $ipc->wait >>. Escalates TERM -> KILL against a wedged
collector parent that should have exited after its job was reaped (the per-test
silence/lifetime timeouts are enforced by the collector itself). This requires
the consuming class to provide a C<settings> accessor exposing
C<< ->runner->use_timeout >> and C<< ->runner >>; both L<Test2::Harness2::Runner>
and L<Test2::Harness2::Preload::Host> do.

=item $ipc->check_for_fork

This is used a lot internally to check if this is a forked process. If this is
a forked process the IPC object is completely reset with no remaining internal
state (except signal handlers).

=item $ipc->set_proc_exit($proc, @args)

Calls C<< $proc->set_exit(@args) >>. This is called by C<< $ipc->wait >>. You
can override it to add custom tasks when a process exits.

=item $int = $ipc->wait()

=item $int = $ipc->wait(%params)

Wait on processes, return the number found.

Default is non-blocking.

Options:

=over 4

=item timeout => $float

When C<< all => $bool >> is set this can be used to break the blocking wait after
a timeout. L<Time::HiRes> is used, so timeout is in seconds with decimals.

=item all => $bool

Block until B<ALL> processes are done.

=back

=item $ipc->watch($proc)

Add a process to be monitored.

=item $proc = $ipc->spawn($proc)

=item $proc = $ipc->spawn(%params)

In the first form $proc is an instance of L<Test2::Harness2::IPC::Process> that
provides C<spawn_params()>.

In the second form the following params are allowed:

Anything supported by C<run_cmd()> in L<Test2::Harness2::Util::IPC>.

=over 4

=item process_class => $CLASS

Default is L<Test2::Harness2::IPC::Process>.

=item command => $command

Program command to call. This is required.

=item env_vars => { ... }

Specify custom environment variables for the new process.

=back

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

package Test2::Harness2::Preload;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX();
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;
use File::Spec();

use Test2::Harness2::Util qw/mod2file/;

# The user-facing preload DSL / stage-tree meta. Distinct from THIS module: this
# is the preload-ROOT bootstrap process, the DSL below is the stage definition
# language a user's preload library uses.
use Test2::Harness2::Runner::Preload();

use Test2::Harness2::Util::HashBase qw{
    <runner_socket
    <workdir
    +responses
    +stopped
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preload - The preload-root bootstrap process.

=head1 DESCRIPTION

This module is the C<-M> bootstrap target for the B<preload root> process the
runner spawns when a run uses preloads (ARCHITECTURE.md §4.7, 19_spec.md §6.1).
The runner forks+execs a clean perl:

    $^X -I... -MTest2::Harness2::Preload=launch,/path/to/runner.socket -e '1;'

Loading this module with the C<launch> argument runs its bootstrap in C<BEGIN>
(compile phase): it establishes the L<Long::Jump> host frame future test
launches unwind to (so a preloaded test forks with no added stack frame -- that
launch path lands in a later chunk), dials the runner over C<runner.socket>,
asks the runner for the preload list, loads those preload libraries, reports the
stage map back to the runner, and then services its channel until the runner
tells it to stop.

It B<is> the compile-time host that used to live inside the runner: moving it
here keeps the runner a pure orchestrator that holds no preloaded interpreter
state.

This is B<not> L<Test2::Harness2::Runner::Preload> (the user-facing preload DSL /
stage-tree meta object); this is the process bootstrap, which consumes that
meta.

=head1 SYNOPSIS

    # Invoked by the runner, never by hand:
    $^X -MTest2::Harness2::Preload=launch,/path/runner.socket -e '1;'

=head1 ATTRIBUTES

=over 4

=item $path = $preload->runner_socket

Absolute path to the runner's C<runner.socket> this process dials.

=item $dir = $preload->workdir

The harness workdir (the directory the sockets live in).

=back

=cut

# Role::Service wants name + workdir. The preload root identifies as
# 'preload-root' to the runner.
sub name { 'preload-root' }

# The -M import IS the entry point: with the 'launch' argument it bootstraps the
# whole process (in BEGIN/compile phase) and exits; with no/other arguments it is
# an ordinary no-op import so the module can be required/use'd (e.g. in tests)
# without launching anything.
sub import {
    my $class = shift;
    my @args  = @_;

    return unless @args && $args[0] eq 'launch';

    my (undef, $socket) = @args;

    $class->launch(runner_socket => $socket);
}

=head1 PUBLIC METHODS

=over 4

=item Test2::Harness2::Preload->launch(runner_socket => $path)

Bootstrap the preload-root process and run it to completion, then exit. Builds
the object, installs the C<Long::Jump> host frame, runs the driver, and
C<POSIX::_exit>s.

=cut

sub launch {
    my $class = shift;
    my %params = @_;

    my $socket = $params{runner_socket}
        or croak "launch requires a runner_socket";

    my $workdir = $params{workdir};
    unless (defined $workdir && length $workdir) {
        # The sockets live in the workdir; derive it from the socket path, falling
        # back to the env the runner propagates to every child (ARCHITECTURE.md §5.3).
        my ($vol, $dir) = File::Spec->splitpath($socket);
        $workdir = File::Spec->catpath($vol, $dir, '');
        $workdir = $ENV{T2_HARNESS_WORKDIR} unless defined $workdir && length $workdir;
    }

    my $self = $class->new(runner_socket => $socket, workdir => $workdir);

    # Establish the Long::Jump host frame at the top of the stack, in compile
    # phase, BEFORE any preloads load -- a future preloaded test launch unwinds
    # here (with no added stack frame) and is swapped in via goto::file. 19.1 has
    # no test launches yet, so the driver returns normally and we exit.
    setjump 'preload-root' => sub { $self->run_driver };

    POSIX::_exit(0);
}

=item $preload->run_driver

Dial the runner, fetch the preload list, load the preloads, report the stage
map, then service the channel until stopped. Never throws: on any error it logs
and idles until the runner reaps it, so it never voluntarily exits mid-run (a
voluntary exit would race the runner's C<waitpid(-1)> reaper).

=cut

sub run_driver {
    my $self = shift;

    my $ok = eval { $self->_handshake; 1 };
    warn "$$ $0 preload-root handshake failed: $@" unless $ok;

    # Service the channel until the runner sends 'stop'. Even if the handshake
    # failed we idle here rather than exit: the runner reaps us at wind-down (and
    # our collector watches the runner pid as the backstop), and a voluntary exit
    # mid-run would trip the runner's waitpid(-1) reaper.
    until ($self->{+STOPPED}) {
        $self->service_io;
        sleep 0.01;
    }

    $self->close_service;

    return;
}

=item $preload->stage_data($meta)

Build the stage map reported to the runner from a merged
L<Test2::Harness2::Runner::Preload> meta object: each user-defined stage name
maps to its eager fan-out (C<can_run>) and whether it is the default. Returns an
empty hashref when there is no staged preload.

=back

=cut

sub stage_data {
    my $self = shift;
    my ($meta) = @_;

    my $data = {};
    return $data unless $meta;

    my $eager   = $meta->eager_stages;
    my $lookup  = $meta->stage_lookup;
    my $default = $meta->default_stage;

    for my $name (keys %$lookup) {
        $data->{$name} = {
            can_run => $eager->{$name} // [],
            default => (defined($default) && $name eq $default) ? 1 : 0,
        };
    }

    return $data;
}

=head1 PRIVATE METHODS

=over 4

=item $self->_handshake

Dial the runner, request the preload list, load the preloads, and report the
stage map.

=item $meta = $self->_load_preloads(\@modules)

Require each preload module and merge those that expose C<TEST2_HARNESS_PRELOAD>
into one meta object. A module that fails to load is warned and skipped.

=item $payload = $self->_request_sync($identity, $command, %args)

Send a request and pump the service loop until its correlated response arrives
(or a timeout fires).

=item $self->service_on_response($conn, $event)

L<Test2::Harness2::Role::Service> hands matched responses here; stash them by
request id for C<_request_sync>.

=back

=cut

sub _handshake {
    my $self = shift;

    $self->start_service;

    my $conn = $self->service_connect_peer('runner', $self->{+RUNNER_SOCKET})
        or croak "preload-root could not connect to runner.socket at '$self->{+RUNNER_SOCKET}'";

    my $list = $self->_request_sync('runner', 'get_preload_list');
    my @mods = @{($list && $list->{preloads}) || []};

    my $meta = $self->_load_preloads(\@mods);

    $self->service_send('runner', 'set_stage_data', stage_data => $self->stage_data($meta));

    return;
}

sub _load_preloads {
    my $self = shift;
    my ($mods) = @_;

    my $meta;
    for my $mod (@$mods) {
        my $file = mod2file($mod);
        my $ok = eval { require $file unless $INC{$file}; 1 };
        my $err = $@;
        unless ($ok) {
            warn "$$ $0 preload-root could not load preload '$mod': $err";
            next;
        }

        next unless $mod->can('TEST2_HARNESS_PRELOAD');

        $meta //= Test2::Harness2::Runner::Preload->new;
        $meta->merge($mod->TEST2_HARNESS_PRELOAD);
    }

    return $meta;
}

sub _request_sync {
    my $self = shift;
    my ($identity, $command, %args) = @_;

    my $conn = $self->service_peer_conn($identity)
        or croak "no connection to peer '$identity'";

    my $request_id = $conn->send_request($command, %args);

    $self->{+RESPONSES} //= {};

    my $deadline = time + 30;
    until (exists $self->{+RESPONSES}{$request_id}) {
        croak "timed out waiting for '$command' response from '$identity'"
            if time > $deadline;
        $self->service_io;
        sleep 0.01;
    }

    return delete $self->{+RESPONSES}{$request_id};
}

sub service_on_response {
    my $self = shift;
    my ($conn, $event) = @_;

    ($self->{+RESPONSES} //= {})->{$event->{request_id}} = $event->{payload};

    return;
}

# Role::Service dispatches an inbound 'stop' request through handle_request ->
# request_handler_stop -> stop_service, which sets the role's stopped flag. Mirror
# that into our own loop flag so the driver loop ends.
sub request_handler_stop {
    my $self = shift;
    $self->{+STOPPED} = 1;
    $self->stop_service;
    return {ok => 1, stopping => 1};
}

1;

__END__

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

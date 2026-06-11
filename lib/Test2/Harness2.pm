package Test2::Harness2;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use Scalar::Util qw/blessed/;
use Time::HiRes ();

use Test2::Collector qw/spawn_collector/;
use Test2::Collector::Recorder::Zstd;
use Test2::Collector::Util::JSON qw/encode_json/;
use Test2::Collector::Util::Socket qw/connect_unix write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;

use Test2::Harness2::Run;

use Object::HashBase qw{
    <project
    <workdir
    <harness_class
    <pid
};

# How long start() waits for the spawned service to bind its request
# socket before giving up.
use constant SOCKET_WAIT_SECONDS => 10;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2 - Start a harness service and queue test runs on it.

=head1 DESCRIPTION

The client handle for the harness. C<start> spawns the harness service as
a new process wrapped in a (non-test) collector, so the service's own
output is recorded to C<harness.jsonl.zst> in the workdir like any other
collected process. The service then loops waiting for test runs; C<queue_run>
sends it a L<Test2::Harness2::Run> over the service's unix socket as a
zstd-compressed JSON object frame, C<shutdown> tells it no more runs are
coming, and C<wait> blocks until it exits.

=head1 SYNOPSIS

    use Test2::Harness2;
    use Test2::Harness2::Run;

    my $harness = Test2::Harness2->new(project => 'MyApp');
    $harness->start;

    $harness->queue_run(Test2::Harness2::Run->new(
        jobs => [{test_file => 't/foo.t', includes => ['lib']}],
    ));

    $harness->shutdown;
    my $exit = $harness->wait;

=head1 ATTRIBUTES

=over 4

=item project

Name of the project this harness serves (required, no default). Used to
build the default workdir path; must not contain a directory separator.

=item workdir

The harness working directory. Defaults to
C<< E<lt>tmpdirE<gt>/t2h2-E<lt>userE<gt>-E<lt>projectE<gt> >>. Created by
C<start> when missing. Sockets, the service's own events file, and every
job's events file live under it.

=item harness_class

The service class C<start> runs in the spawned process. Defaults to
L<Test2::Harness2::Service::Harness>.

=item pid

Process id of the spawned service collector, set by C<start>.

=back

=cut

sub init ($self) {
    croak "'project' is a required attribute"
        unless defined $self->{+PROJECT} && length $self->{+PROJECT};
    croak "'project' must not contain a directory separator"
        if $self->{+PROJECT} =~ m{/};

    $self->{+WORKDIR}       //= $self->_default_workdir;
    $self->{+HARNESS_CLASS} //= 'Test2::Harness2::Service::Harness';

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $pid = $harness->start

Create the workdir if needed, spawn the service process (wrapped in a
non-test collector recording to C<harness.jsonl.zst> in the workdir), and
wait for the service's request socket to appear. Returns the collector's
pid (also stored in C<pid>). Croaks if this handle already started a
service.

=cut

sub start ($self) {
    croak "this harness was already started (pid $self->{+PID})" if $self->{+PID};

    my $workdir = $self->{+WORKDIR};
    make_path($workdir) unless -d $workdir;

    my $class = $self->{+HARNESS_CLASS};
    my $file  = $class =~ s{::}{/}gr . '.pm';
    croak "could not load harness class '$class': $@" unless eval { require $file; 1 };

    # The service returns 0 from run(); a normal run_sub return becomes a 0
    # exit for the collected child, and a die becomes 255.
    $self->{+PID} = spawn_collector(
        name     => 'harness',
        run_sub  => sub ($guard) { $class->new(workdir => $workdir)->run },
        recorder => Test2::Collector::Recorder::Zstd->new(file => "$workdir/harness.jsonl.zst"),
    );

    $self->_wait_for_socket;

    return $self->{+PID};
}

=item $harness->queue_run($run)

Send one L<Test2::Harness2::Run> (or a hashref of its constructor
arguments) to the running service. The run must be in its complete final
form; nothing is sniffed or filled in on the way through.

=item $harness->shutdown

Tell the service no more runs are coming. It finishes everything already
queued, then exits.

=cut

sub queue_run ($self, $run) {
    $run = Test2::Harness2::Run->new(%$run) if ref($run) eq 'HASH';
    croak "queue_run requires a Test2::Harness2::Run (or a hashref of its constructor arguments)"
        unless blessed($run) && $run->isa('Test2::Harness2::Run');

    $self->_send_request({queue_run => $run});
    return;
}

sub shutdown ($self) {
    $self->_send_request({shutdown => \1});
    return;
}

=item $exit = $harness->wait

Block until the service process exits; returns its wait status (C<$?>
style -- C<0> means a clean exit).

=back

=cut

sub wait ($self) {
    my $pid = $self->{+PID} or croak "this harness was never started";
    waitpid($pid, 0);
    $self->{+PID} = undef;
    return $?;
}

=head1 PRIVATE METHODS

=over 4

=item $path = $self->_default_workdir

C<< E<lt>tmpdirE<gt>/t2h2-E<lt>userE<gt>-E<lt>projectE<gt> >>.

=item $path = $self->_socket_path

The service's request socket path, as published by the harness class.

=item $self->_send_request($data)

Connect to the service socket, write C<$data> as one zstd-compressed JSON
object frame, and disconnect.

=item $self->_wait_for_socket

Poll for the service's request socket to appear after a spawn; dies when
it does not show up in time.

=back

=cut

sub _default_workdir ($self) {
    my $user = $ENV{USER} // getpwuid($<) // 'unknown';
    return File::Spec->tmpdir . "/t2h2-$user-$self->{+PROJECT}";
}

sub _socket_path ($self) {
    return $self->{+HARNESS_CLASS}->socket_path($self->{+WORKDIR});
}

sub _send_request ($self, $data) {
    my $sock = connect_unix($self->_socket_path);
    write_frame($sock, compress_blob(encode_json($data)));
    close($sock);
    return;
}

sub _wait_for_socket ($self) {
    my $path     = $self->_socket_path;
    my $deadline = Time::HiRes::time() + SOCKET_WAIT_SECONDS;

    until (-S $path) {
        die "harness service did not create its socket at '$path' within " . SOCKET_WAIT_SECONDS . "s"
            if Time::HiRes::time() > $deadline;
        Time::HiRes::sleep(0.05);
    }

    return;
}

1;

__END__

=pod

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

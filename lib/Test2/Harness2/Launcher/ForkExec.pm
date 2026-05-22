package Test2::Harness2::Launcher::ForkExec;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Errno qw/EAGAIN ENOMEM/;
use POSIX ();
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Collector;

use Object::HashBase qw{
    +name
    <handle
    <parser
    <auditor
    <recorder
    <silence_timeout
    <lifetime_timeout
    <orphan_timeout
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Launcher';

sub name { $_[0]->{+NAME} //= 'forkexec' }

sub launch {
    my ($self, $job_try) = @_;
    return (ok => 0, error => "launch requires a job_try row", temporary => 0)
        unless blessed($job_try) && $job_try->can('job_id');

    my $handle = $self->handle
        or return (ok => 0, error => "launcher has no handle", temporary => 0);

    my $job = $handle->fetch(jobs => {job_id => $job_try->job_id});
    return (ok => 0, error => "no job row for job_id=" . $job_try->job_id, temporary => 0)
        unless $job;

    my $spec = $self->_decode_spec($job)
        or return (ok => 0, error => "jobs.spec is not a hash", temporary => 0);

    my $test_file = $spec->{test_file};
    return (ok => 0, error => "jobs.spec missing 'test_file'", temporary => 0)
        unless defined $test_file && length $test_file;

    my @includes = @{$spec->{includes} || []};
    my @modules  = @{$spec->{modules}  || []};

    my @argv = ($^X);
    push @argv, map { "-I$_" } @includes;
    push @argv, map { "-M$_" } @modules;
    push @argv, $test_file;

    my $pid = fork;
    if (!defined $pid) {
        my $err = "$!";
        my $temporary = ($!{EAGAIN} || $!{ENOMEM}) ? 1 : 0;
        return (ok => 0, error => "fork: $err", temporary => $temporary);
    }

    return (ok => 1, pid => $pid) if $pid;

    $self->_run_collector(\@argv, $spec);
    POSIX::_exit(255);
}

sub _decode_spec {
    my ($self, $job) = @_;
    my $raw = $job->spec;
    return {} unless defined $raw && length $raw;
    return $raw if ref($raw) eq 'HASH';
    my $decoded = eval { decode_json($raw) };
    return $decoded if ref($decoded) eq 'HASH';
    return undef;
}

sub _run_collector {
    my ($self, $argv, $spec) = @_;

    if (defined $spec->{cwd}) {
        chdir($spec->{cwd}) or do {
            print STDERR "ForkExec: chdir($spec->{cwd}) failed: $!\n";
            POSIX::_exit(254);
        };
    }

    if (my $env = $spec->{env}) {
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    my $ok = eval {
        Test2::Harness2::Collector->start(
            is_test          => 1,
            exec             => $argv,
            parser           => $self->{+PARSER},
            auditor          => $self->{+AUDITOR},
            recorder         => $self->{+RECORDER},
            silence_timeout  => $self->{+SILENCE_TIMEOUT},
            lifetime_timeout => $self->{+LIFETIME_TIMEOUT},
            orphan_timeout   => $self->{+ORPHAN_TIMEOUT},
        );
        1;
    };
    my $err = $@;
    if (!$ok) {
        print STDERR "ForkExec: Collector->start died: $err\n";
        POSIX::_exit(255);
    }
    POSIX::_exit(0);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Launcher::ForkExec - POSIX fork+exec launcher.

=head1 DESCRIPTION

The default launcher on every POSIX-y platform. Consumes
L<Test2::Harness2::Role::Launcher>; an in-process object owned by the
scheduler. C<launch> forks once in the caller's process; the
collector inherits the caller's process state (already-loaded
modules, etc.) and is built in-process via
L<Test2::Harness2::Collector/start>. The collector itself then forks
the test process per L<Test2::Harness2::Collector>'s contract,
C<exec>ing C<$^X> with the C<-I> / C<-M> args derived from
C<jobs.spec> plus the absolute C<test_file> path.

The result is a single fork in the scheduler (producing the collector)
plus a single fork+exec in the collector (producing the test).

=head1 SYNOPSIS

    use Test2::Harness2::Launcher::ForkExec;
    use Test2::Harness2::Collector::Recorder::Files;

    my $rec = Test2::Harness2::Collector::Recorder::Files->new(dir => $tmp);

    my $l = Test2::Harness2::Launcher::ForkExec->new(
        name     => 'fe',
        handle   => $harness_handle,
        parser   => 'Test2::Harness2::Collector::Parser::TAPParser',
        auditor  => 'Test2::Harness2::Collector::Auditor::Test',
        recorder => $rec,
    );

    my %reply = $l->launch($job_try);

    if ($reply{ok}) {
        # scheduler reaps $reply{pid} (the collector pid) in its loop
    }
    else {
        # $reply{error}, $reply{temporary}
    }

=head1 ATTRIBUTES

=over 4

=item name

Short identifier, defaults to C<'forkexec'>.

=item handle (required)

The L<Test2::Harness2> handle. C<launch> uses it to fetch the C<jobs>
row referenced by the supplied C<job_try>.

=item parser

Parser class name (or instance) handed to the collector. Typically
L<Test2::Harness2::Collector::Parser::TAPParser>.

=item auditor

Auditor class name (or instance) handed to the collector. Typically
L<Test2::Harness2::Collector::Auditor::Test>. May be left unset for
service-style collectors that do not audit.

=item recorder

Recorder class name (or instance) handed to the collector. Typically
L<Test2::Harness2::Collector::Recorder::DB> in production, or a
preconstructed L<Test2::Harness2::Collector::Recorder::Files> for
tests / development drivers.

=item silence_timeout, lifetime_timeout, orphan_timeout

Defaults handed to the collector. C<undef> leaves the collector's own
defaults in place (see L<Test2::Harness2::Collector>).

=back

=head1 PUBLIC METHODS

=over 4

=item %reply = $l->launch($job_try)

Resolve the C<jobs> row for C<$job_try>, decode C<jobs.spec>, build
the test argv (C<$^X> + C<-I@includes> + C<-M@modules> +
C<$test_file>), fork, and in the child run
L<Test2::Harness2::Collector/start> with the launcher's parser /
auditor / recorder / timeout configuration. Returns
C<(ok =E<gt> 1, pid =E<gt> $collector_pid)> on success; on failure
returns C<(ok =E<gt> 0, error =E<gt> $reason, temporary =E<gt> 0|1)>.

C<fork> failures with C<EAGAIN> / C<ENOMEM> are classified
temporary; bad spec / missing C<test_file> / missing job row are
permanent.

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

package Test2::Harness2::Launcher::Win32;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util::JSON qw/decode_json encode_json/;

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

# Inline bootstrap the spawned perl runs. Reads a JSON spec from
# STDIN, requires the named parser / auditor / recorder classes,
# and starts the collector. Kept as a string constant so it can be
# fed straight to `system(1, $^X, '-e', $BOOTSTRAP)`.
my $BOOTSTRAP = <<'PERL';
use strict;
use warnings;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Collector;
local $/;
my $bytes = <STDIN>;
die "Win32 collector bootstrap: no spec on STDIN\n"
    unless defined $bytes && length $bytes;
my $spec = decode_json($bytes);
ref($spec) eq 'HASH'
    or die "Win32 collector bootstrap: spec is not a JSON object\n";
for my $key (qw/parser auditor recorder/) {
    my $cls = $spec->{$key};
    next unless defined $cls && !ref($cls) && length $cls;
    (my $file = $cls) =~ s{::}{/}g;
    require "$file.pm";
}
my $exit = Test2::Harness2::Collector->start(%$spec);
exit(defined $exit ? $exit : 0);
PERL

sub name { $_[0]->{+NAME} //= 'win32' }

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

    my %collector_spec = (
        is_test          => 1,
        exec             => \@argv,
        parser           => $self->_class_name($self->{+PARSER}),
        auditor          => $self->_class_name($self->{+AUDITOR}),
        recorder         => $self->_class_name($self->{+RECORDER}),
        silence_timeout  => $self->{+SILENCE_TIMEOUT},
        lifetime_timeout => $self->{+LIFETIME_TIMEOUT},
        orphan_timeout   => $self->{+ORPHAN_TIMEOUT},
    );
    # Strip undefs so the bootstrap sees a clean hash.
    for my $k (keys %collector_spec) {
        delete $collector_spec{$k} unless defined $collector_spec{$k};
    }

    if (defined $spec->{cwd}) {
        $collector_spec{cwd} = $spec->{cwd};
    }
    if (my $env = $spec->{env}) {
        $collector_spec{env} = $env;
    }

    pipe(my $r, my $w)
        or return (ok => 0, error => "pipe: $!", temporary => 1);

    open(my $saved_stdin, '<&', \*STDIN)
        or return (ok => 0, error => "save STDIN: $!", temporary => 0);
    open(STDIN, '<&=', fileno($r))
        or return (ok => 0, error => "dup pipe to STDIN: $!", temporary => 0);

    my $pid = system(1, $^X, '-e', $BOOTSTRAP);
    my $sys_err = "$!";

    open(STDIN, '<&', $saved_stdin)
        or warn "Win32 launcher: restore STDIN failed: $!\n";
    close($saved_stdin);
    close($r);

    if (!$pid || $pid <= 0) {
        close($w);
        return (ok => 0, error => "system(1,...) returned no pid: $sys_err", temporary => 0);
    }

    my $ok = eval {
        print {$w} encode_json(\%collector_spec);
        close($w);
        1;
    };
    if (!$ok) {
        my $err = $@;
        return (ok => 0, error => "failed to write spec to child: $err", temporary => 0);
    }

    return (ok => 1, pid => $pid);
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

sub _class_name {
    my ($self, $thing) = @_;
    return undef unless defined $thing;
    return $thing unless blessed($thing);
    # On Win32 a pre-built instance cannot survive the system(1) hop; the
    # bootstrap will construct its own instance from the class name.
    return ref($thing);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Launcher::Win32 - Windows launcher (best-effort,
untested in CI on POSIX hosts).

=head1 DESCRIPTION

Windows analogue of L<Test2::Harness2::Launcher::ForkExec>. Windows
has no C<fork>, so the launcher spawns a fresh perl via Perl's
C<system(1, $^X, '-e', $bootstrap)> form. That fresh perl is the
collector process. The launcher hands the collector spec to the
spawned perl as a JSON object on its stdin; the bootstrap inside
the spawned perl decodes the JSON, requires the parser / auditor /
recorder classes, and calls L<Test2::Harness2::Collector/start>. The
collector then itself spawns (also via C<system(1, ...)>, internally)
the test process.

Because C<system(1, ...)> cannot inherit Perl state across the
spawn, the collector starts in a fresh interpreter rather than
inheriting from the scheduler. Pre-built parser / auditor / recorder
instances also cannot cross the boundary; the launcher passes class
names only and the bootstrap reconstructs instances via C<< $class->new >>.

L<Test2::Harness2::Launcher::Default> picks between this class and
L<Test2::Harness2::Launcher::ForkExec> at construction based on
C<$^O>, so callers normally do not name this class directly.

=head1 ATTRIBUTES

Same as L<Test2::Harness2::Launcher::ForkExec/ATTRIBUTES>.

=head1 PUBLIC METHODS

=over 4

=item %reply = $l->launch($job_try)

Same outward contract as L<Test2::Harness2::Launcher::ForkExec/launch>:
returns C<(ok =E<gt> 1, pid =E<gt> $collector_pid)> on success or
C<(ok =E<gt> 0, error =E<gt> $reason, temporary =E<gt> 0|1)> on
failure. Internally swaps stdin to a pipe before C<system(1, ...)> so
the spawned perl inherits the pipe as its stdin; writes the JSON spec
through that pipe; closes it to signal EOF.

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

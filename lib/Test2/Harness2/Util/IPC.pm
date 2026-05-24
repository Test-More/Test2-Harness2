package Test2::Harness2::Util::IPC;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak confess/;
use Errno qw/ESRCH/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    parse_exit
    pid_is_running
    set_procname
    swap_io
    atomic_pipe_compression_args
    apply_atomic_pipe_compression
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::IPC - Low-level process helpers shared across the
harness.

=head1 DESCRIPTION

A bag of process-helper functions used by the collector and other harness
processes: file-descriptor swapping, wait-status decoding, and the
L<Atomic::Pipe> compression defaults.

Despite the module name, this is the process-helper bag, not anything
related to the legacy C<IPC::Manager> stack.

=head1 SYNOPSIS

    use Test2::Harness2::Util::IPC qw/swap_io parse_exit/;

    open(my $log, '>>', '/tmp/out.log') or die $!;
    swap_io(\*STDOUT, $log);

    my $codes = parse_exit($?);

=head1 EXPORTS

=cut

=over 4

=item $codes = parse_exit($wstat)

Decode a wait-status integer (typically C<$?>) into a hashref with C<sig>
(low 7 bits), C<err> (exit code, upper bits), C<dmp> (core-dump bit), and
C<all> (the original raw value). Croaks if C<$wstat> is undefined.

=back

=cut

sub parse_exit ($exit) {
    croak "an exit value is required" unless defined $exit;

    return {
        sig => $exit & 127,
        err => ($exit >> 8),
        dmp => $exit & 128,
        all => $exit,
    };
}

=over 4

=item $state = pid_is_running($pid)

Probe whether C<$pid> is alive via a zero signal. Returns C<1> when the
process exists and is signalable by us, C<0> when it does not exist
(C<ESRCH>), and C<-1> when it exists but is owned by another user (signal
denied). Croaks if C<$pid> is missing or zero.

=back

=cut

sub pid_is_running ($pid) {
    confess "A pid is required" unless $pid;

    local $!;

    return 1 if kill(0, $pid);    # Running and we may signal it
    return 0 if $! == ESRCH;      # Does not exist
    return -1;                    # Running, but not ours
}

=over 4

=item set_procname(%params)

Set C<$0> so process listings show what this process is. C<set> (scalar or
arrayref) supplies the descriptive parts (defaults to the current C<$0>);
C<append> (scalar or arrayref) adds trailing parts. The result is prefixed
with C<prefix> (defaults to C<$ENV{T2_HARNESS2_PROC_PREFIX}> or
C<Test2-Harness2>) unless it already carries that prefix.

=back

=cut

sub set_procname (%params) {
    my $prefix = $params{prefix} // $ENV{T2_HARNESS2_PROC_PREFIX} // 'Test2-Harness2';
    my $append = $params{append} // [];
    my $set    = $params{set}    // [];

    $append = [$append] unless ref($append);
    $set    = [$set]    unless ref($set);

    my $name = join('-', (@$set ? @$set : $0), @$append);
    $name = "${prefix}-${name}" unless $name =~ m/^\Q$prefix\E-/;

    $0 = $name;
    return;
}

=over 4

=item swap_io($fh, $to)

Reopen C<$fh> as a duplicate of C<$to> while preserving its file-descriptor
number. Croaks if the resulting fd does not match.

=back

=cut

sub swap_io ($fh, $to) {
    my $orig_fd = fileno($fh);
    croak "Could not get fd for handle" unless defined $orig_fd;

    open($fh, '>&', $to) or croak "Could not redirect fd $orig_fd: $!";

    croak "Handle does not have the expected fd (got " . fileno($fh) . ", wanted $orig_fd)"
        if fileno($fh) != $orig_fd;

    return;
}

=over 4

=item atomic_pipe_compression_args

=item %args = atomic_pipe_compression_args()

Return the default kwargs for L<Atomic::Pipe> constructors: zstd compression
on the framed write paths, plus C<keep_compressed> so readers can stash the
on-wire compressed bytes alongside the decompressed payload (the collector
caches the frame so the events file can write it verbatim).

=back

=cut

sub atomic_pipe_compression_args () {
    return (
        compression     => 'zstd',
        keep_compressed => 1,
    );
}

=over 4

=item apply_atomic_pipe_compression($pipe)

Configure compression on an existing L<Atomic::Pipe> instance to match
L</atomic_pipe_compression_args>. Used by wrappers that construct via
C<from_fh> / C<from_fd>, which do not accept constructor-time compression
kwargs. Idempotent.

=back

=cut

sub apply_atomic_pipe_compression ($pipe) {
    return unless $pipe;
    $pipe->set_compression('zstd');
    $pipe->set_keep_compressed(1);
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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

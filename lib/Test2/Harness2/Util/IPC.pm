package Test2::Harness2::Util::IPC;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak confess/;
use Errno qw/ESRCH/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    pid_is_running
    set_procname
    start_process
    swap_io
    list_direct_children
    atomic_pipe_compression_args
    apply_atomic_pipe_compression
};

use constant HAS_PARSEABLE_PROC => ($^O eq 'linux' || $^O eq 'freebsd' || $^O eq 'dragonfly');

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::IPC - Low-level process helpers shared across
the harness.

=head1 DESCRIPTION

A bag of process-helper functions used by the collector and other
harness processes for cross-process work: liveness checks, process-
name annotation, file-descriptor swapping, child-pid enumeration, and
the Atomic::Pipe compression defaults.

Despite the module name, this is the process-helper bag, not anything
related to the legacy C<IPC::Manager> stack.

=head1 SYNOPSIS

    use Test2::Harness2::Util::IPC qw{
        pid_is_running set_procname swap_io list_direct_children
    };

    if (my $rc = pid_is_running($child_pid)) {
        # 1  -> running and we own it
        # -1 -> running but owned by someone else
    }

    set_procname(set => ['Collector', $child_pid]);

    open(my $log, '>>', '/tmp/out.log') or die $!;
    swap_io(\*STDOUT, $log);

    my @kids = list_direct_children($$);

=head1 EXPORTS

=cut

=item $bool_or_neg = pid_is_running($pid)

Returns C<1> if C<$pid> is running and we own it, C<0> if it is gone,
and C<-1> if it is running but owned by someone else.

=cut

sub pid_is_running {
    my ($pid) = @_;

    confess "A pid is required" unless $pid;

    local $!;

    return 1 if kill(0, $pid);
    return 0 if $! == ESRCH;
    return -1;
}

=item set_procname(%params)

Set C<$0> with an optional C<prefix> (default C<Test2-Harness2>,
overridable via the C<T2_HARNESS2_PROC_PREFIX> env var). Pass
C<< set => [...] >> to replace the body, or C<< append => [...] >> to
append to the current C<$0>.

=cut

sub set_procname {
    my %params = @_;

    my $prefix = $params{prefix} // $ENV{T2_HARNESS2_PROC_PREFIX} // 'Test2-Harness2';
    my $append = $params{append} // [];
    my $set    = $params{set}    // [];

    $append = [$append] unless ref($append);
    $set    = [$set]    unless ref($set);

    my $name = join('-', (@$set ? @$set : $0), @$append);

    $name = "${prefix}-${name}" unless $name =~ m/^\Q$prefix\E-/;

    $0 = $name;
}

=item $pid = start_process(\@cmd, \&post_fork)

Fork and C<exec> C<\@cmd> in the child. The optional C<\&post_fork>
runs in the child just before C<exec>. Returns the child pid in the
parent. The child writes a diagnostic to STDERR and exits 255 on
exec failure.

=cut

sub start_process {
    my ($cmd, $post_fork) = @_;

    confess "cmd is required and must be an arrayref with content" unless $cmd && @$cmd;
    confess "cmd may not contain undefined values" if grep { !defined($_) } @$cmd;

    my $pid = fork // die "Could not fork: $!";
    return $pid if $pid;

    $post_fork->() if $post_fork;

    { no warnings; exec(@$cmd) }
    print STDERR "Failed to exec " . join(' ', @$cmd) . ": $!\n";
    exit(255);
}

=item swap_io($fh, $to)

Reopen C<$fh> as a duplicate of C<$to> while preserving its file
descriptor number. Croaks if the resulting fd does not match.

=cut

sub swap_io {
    my ($fh, $to) = @_;

    my $orig_fd = fileno($fh);
    croak "Could not get fd for handle" unless defined $orig_fd;

    open($fh, '>&', $to) or croak "Could not redirect fd $orig_fd: $!";

    croak "Handle does not have the expected fd (got " . fileno($fh) . ", wanted $orig_fd)"
        if fileno($fh) != $orig_fd;
}

=item @pids = list_direct_children($parent)

Return the pids that are direct children of C<$parent>. Prefers
C</proc/*/status> (Linux, FreeBSD, DragonFlyBSD when procfs is
mounted) and falls back to C<ps -A -o pid=,ppid=> (with C<-e> as a
System-V fallback). Returns an empty list if neither source is
usable.

Intended for post-fork bookkeeping where a service acting as a child
subreaper needs to reach reparented descendants. Not a hot-path
helper -- procfs walks and C<ps> are reserved for shutdown / one-off
calls.

=cut

sub list_direct_children {
    my ($parent) = @_;

    return _list_direct_children_proc($parent) if HAS_PARSEABLE_PROC && -d '/proc';
    return _list_direct_children_ps($parent);
}

=item %args = atomic_pipe_compression_args()

Return the default kwargs for L<Atomic::Pipe> constructors: zstd
compression on the framed write paths, plus C<keep_compressed> so
readers can stash the on-wire compressed bytes alongside the
decompressed payload (the collector caches the frame so a downstream
zstd logger can write it verbatim).

=cut

sub atomic_pipe_compression_args {
    return (
        compression     => 'zstd',
        keep_compressed => 1,
    );
}

=item apply_atomic_pipe_compression($pipe)

Configure compression on an existing L<Atomic::Pipe> instance to
match L</atomic_pipe_compression_args>. Used by wrappers that
construct via C<from_fh> / C<from_fd>, which do not accept
constructor-time compression kwargs. Idempotent.

=cut

sub apply_atomic_pipe_compression {
    my ($pipe) = @_;
    return unless $pipe;
    $pipe->set_compression('zstd');
    $pipe->set_keep_compressed(1);
    return;
}

sub _list_direct_children_proc {
    my ($parent) = @_;
    return () unless -d '/proc';

    opendir(my $dh, '/proc') or return ();
    my @kids;
    while (defined(my $ent = readdir $dh)) {
        next unless $ent =~ /\A[0-9]+\z/;
        next if $ent == $parent;

        open(my $fh, '<', "/proc/$ent/status") or next;
        local $/;
        my $content = <$fh>;
        close($fh);

        my $ppid = _parse_proc_status_ppid($content);
        push @kids => $ent + 0 if defined $ppid && $ppid == $parent;
    }
    closedir $dh;

    return @kids;
}

sub _parse_proc_status_ppid {
    my ($content) = @_;
    return undef unless defined $content && length $content;

    return $1 + 0 if $content =~ /^PPid:\s+(\d+)/m;
    return $1 + 0 if $content =~ /\A\S+\s+\d+\s+(\d+)\b/;
    return undef;
}

sub _list_direct_children_ps {
    my ($parent) = @_;

    for my $flag ('-A', '-e') {
        my $cmd = "ps $flag -o pid= -o ppid= 2>/dev/null";
        open(my $fh, '-|', $cmd) or next;

        local $/;
        my $content = <$fh>;
        close($fh);

        next unless defined $content && length $content;

        return grep { kill(0, $_) } _parse_ps_pid_ppid($content, $parent);
    }

    return ();
}

sub _parse_ps_pid_ppid {
    my ($content, $parent) = @_;
    my @kids;
    for my $line (split /\n/, $content // '') {
        next unless $line =~ /\A\s*(\d+)\s+(\d+)\s*\z/;
        push @kids => $1 + 0 if $2 == $parent && $1 != $parent;
    }
    return @kids;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

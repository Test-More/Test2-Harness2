package Test2::Harness2::Util::SubReaper;
use v5.38;

our $VERSION = '2.000000';

use POSIX();

use Importer Importer => 'import';

our @EXPORT_OK = qw/acquire_subreaper release_subreaper subreaper_supported subreaper_mechanism/;

# Linux: prctl(PR_SET_CHILD_SUBREAPER, 1). PR_SET_CHILD_SUBREAPER is a constant
# (36) across architectures; only the prctl syscall number varies by arch.
use constant PR_SET_CHILD_SUBREAPER => 36;

# FreeBSD: procctl(P_PID, getpid(), PROC_REAP_ACQUIRE|PROC_REAP_RELEASE, NULL).
# These constants come from FreeBSD's sys/procctl.h + syscalls.master and are
# FreeBSD-specific -- NOT shared with the other BSDs (DragonFly's SYS_procctl and
# PROC_REAP_* values differ; see the freebsd branch in _resolve_platform).
use constant P_PID               => 0;
use constant PROC_REAP_ACQUIRE   => 2;
use constant PROC_REAP_RELEASE   => 3;
use constant SYS_procctl_FREEBSD => 544;

# Sentinel in a prepared arg list replaced with the live $$ at syscall time. A
# real pid is never negative, so this can never collide with a genuine value.
use constant PID_SLOT => -987654321;

# SYS_prctl by Linux architecture. Keyed off the machine field of POSIX::uname
# (the running kernel's arch), with $Config{archname} as a fallback. An untabled
# arch is treated as unsupported (graceful no-op) rather than guessed.
my %LINUX_SYS_PRCTL = (
    x86_64  => 157,
    aarch64 => 167,
    arm64   => 167,
    riscv64 => 167,
    i386    => 172,
    i486    => 172,
    i586    => 172,
    i686    => 172,
);

# Resolve (mechanism, syscall-number, acquire-args, release-args) for the running
# (OS, arch), or empty if unsupported. Cached after the first resolve. The syscall
# ABI is the same regardless of caller, so a module-level cache is correct.
my ($MECHANISM, $SYS_NUM, @ACQUIRE_ARGS, @RELEASE_ARGS);

# Resolved once at first use (lazily, so it runs after the lexical tables above
# are initialized rather than at BEGIN time). All callers funnel through here.
my $RESOLVED;

sub _ensure_resolved {
    return if $RESOLVED;
    $RESOLVED = 1;
    ($MECHANISM, $SYS_NUM, my $acq, my $rel) = _resolve_platform();
    @ACQUIRE_ARGS = $acq ? @$acq : ();
    @RELEASE_ARGS = $rel ? @$rel : ();
    return;
}

sub _resolve_platform {
    my @uname = eval { POSIX::uname() };
    my $os    = lc($uname[0] // $^O);
    my $arch  = $uname[4] // '';

    if ($os eq 'linux') {
        require Config;
        my $key = $arch;
        $key = $Config::Config{archname} unless $LINUX_SYS_PRCTL{$key};
        $key =~ s/-linux.*$// if defined $key;

        my $num = $LINUX_SYS_PRCTL{$key // ''} // return;

        return (
            'prctl',
            $num,
            [PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0],
            [PR_SET_CHILD_SUBREAPER, 0, 0, 0, 0],
        );
    }

    if ($os eq 'freebsd') {
        # procctl's second arg is id_t == int64. Perl's syscall() marshals each
        # numeric arg as one native word, which only matches the ABI on LP64; on
        # 32-bit FreeBSD (i386/armv7/powerpc) the 64-bit id would span two slots
        # and the cmd would be read from the wrong position, so report
        # unsupported there instead of issuing a mis-marshaled syscall.
        require Config;
        return unless ($Config::Config{ptrsize} // 0) == 8;

        # The pid (second arg) is injected live in _do_syscall via the PID_SLOT
        # sentinel so it is always the current process even if the platform was
        # resolved before a fork.
        return (
            'procctl',
            SYS_procctl_FREEBSD,
            [P_PID, PID_SLOT, PROC_REAP_ACQUIRE, 0],
            [P_PID, PID_SLOT, PROC_REAP_RELEASE, 0],
        );
    }

    # DragonFly BSD is deliberately NOT tabled here: its procctl is a DIFFERENT
    # syscall number (believed 536 -- 548 is wait6 there) with DIFFERENT
    # PROC_REAP_* command values than FreeBSD. Tabling it without verifying on a
    # real DragonFly system would trade one false-positive for another, so it
    # reports unsupported (graceful no-op) until confirmed.

    return;
}

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::SubReaper - Mark the current process as a child subreaper
(pure-Perl, no XS).

=head1 DESCRIPTION

A child subreaper becomes the adoptive parent of any orphaned descendant (one
whose immediate parent has exited, as happens after a double-fork or
C<setsid> + parent exit), instead of that descendant reparenting to C<init(1)>.
This lets a long-running parent reliably C<waitpid> its grandchildren and own
reaping for its whole process subtree.

The harness uses this to make the runner the single reaper of the process tree:
the runner acquires the subreaper flag at startup, and preload-spawned test
collectors double-fork and detach so they reparent up to the runner (on a
supported platform) instead of being reaped by the preload tree.

This is a pure-Perl reimplementation that issues the native primitive through
C<syscall()> with a per-(OS, arch) number table, so the distribution needs no XS
and no compiler at install. It supports Linux
(C<prctl(PR_SET_CHILD_SUBREAPER)>) and 64-bit FreeBSD
(C<procctl(..., PROC_REAP_ACQUIRE)>). DragonFly BSD is deliberately unsupported
(its C<procctl> syscall number and C<PROC_REAP_*> constants differ from
FreeBSD's and are unverified). Every other platform, and any unknown
architecture, is a graceful no-op reported as "unsupported"; the caller falls
back to C<init> owning the orphans.

=head1 SYNOPSIS

    use Test2::Harness2::Util::SubReaper qw/acquire_subreaper subreaper_supported/;

    if (subreaper_supported()) {
        acquire_subreaper() or warn "subreaper setup failed: $!";
    }

=head1 EXPORTS

Nothing is exported by default; request functions explicitly.

=over 4

=item $bool = subreaper_supported()

True when the running (OS, arch) has a subreaper mechanism this module can issue
via C<syscall()> (Linux on a tabled architecture, or 64-bit FreeBSD). Makes no
syscall; safe on any platform.

=item $name = subreaper_mechanism()

A short string naming the mechanism (C<"prctl"> on Linux, C<"procctl"> on
64-bit FreeBSD) or C<undef> when unsupported. Invariant:
C<< !!subreaper_supported() == defined(subreaper_mechanism()) >>.

=item $bool = acquire_subreaper()

Mark the current process as a child subreaper. Returns true on success, false on
an unsupported platform or a failed syscall (with C<$!> set by the kernel). Never
throws: the syscall is eval-guarded so an unexpected platform cannot kill the
caller.

=item $bool = release_subreaper()

Clear the subreaper flag on the current process (the inverse of
C<acquire_subreaper>). Same return/failure semantics. On Linux this is
C<prctl(PR_SET_CHILD_SUBREAPER, 0)>; on BSD it is C<PROC_REAP_RELEASE>.

=back

=cut

sub subreaper_supported { _ensure_resolved(); $MECHANISM ? 1 : 0 }
sub subreaper_mechanism { _ensure_resolved(); $MECHANISM }

sub acquire_subreaper { _ensure_resolved(); return _do_syscall(@ACQUIRE_ARGS) }
sub release_subreaper { _ensure_resolved(); return _do_syscall(@RELEASE_ARGS) }

=pod

=head1 PRIVATE FUNCTIONS

=over 4

=item $bool = _do_syscall(@args)

Issue the resolved subreaper C<syscall()> with the prepared argument list. Returns
true when the kernel reports success (C<syscall> returns 0), false otherwise. A
syscall on an unexpected ABI can die; that is caught and reported as failure so a
caller on an odd platform degrades to "unsupported" rather than crashing.

=back

=cut

sub _do_syscall {
    my (@args) = @_;

    return 0 unless $MECHANISM;

    @args = map { $_ == PID_SLOT ? $$ : $_ } @args;

    my $rv;
    my $ok = eval {
        # syscall() returns -1 on failure (with $! set), 0 on success for these
        # ops. We pass the raw syscall number, so no syscall.ph is required.
        $rv = syscall($SYS_NUM, @args);
        1;
    };

    return 0 unless $ok;
    return $rv == 0 ? 1 : 0;
}

1;

__END__

=head1 PORTABILITY

The module loads cleanly on every platform; platform resolution happens on first
use and any unknown (OS, arch) simply reports unsupported. Listing it as a
dependency never fails an install because it ships no XS.

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

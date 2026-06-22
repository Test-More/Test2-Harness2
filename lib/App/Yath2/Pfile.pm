package App::Yath2::Pfile;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use App::Yath2::Discovery();

use Test2::Harness2::Util::HashBase qw{
    <discovery
    +data
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Pfile - Discovery reader for a persistent runner (the well-known
symlink to its C<runner.socket>).

=head1 DESCRIPTION

A persistent runner publishes a well-known B<symlink> pointing at its
C<runner.socket>; following the symlink reaches the socket and (via the socket's
directory) the runner's B<workdir>. The runner's pid is read from the flat C<PID>
file in that workdir for signal-based termination of a wedged runner. This
replaces the old C<yath-persist.json> metadata file.

Every command that talks to (or merely locates) a persistent runner --
C<run>/C<spawn>/C<stop>/C<which>/C<watch>/C<reload> -- needs to find that runner,
read its pid, and find its workdir. This class is the one shared consumer of the
discovery symlink: L</find> wraps L<App::Yath2::Discovery/find> (which performs
the symlink-resolves-to-a-live-socket check and cleans a stale symlink) and an
instance then exposes the pid and workdir behind the same accessors the inline
re-reads used to.

=head1 SYNOPSIS

    use App::Yath2::Pfile;

    # Locate the persistent runner for the current settings (returns nothing if
    # the symlink is missing or points at a dead runner, like which/watch/stop):
    my $pfile = App::Yath2::Pfile->find($settings)
        or die "No persistent harness was found for the current path.\n";

    print $pfile->describe;    # the "Found / PID / Dir" banner
    my $dir = $pfile->workdir;
    my $pid = $pfile->pid;

=head1 PUBLIC METHODS

=over 4

=item find

=item $pfile = App::Yath2::Pfile->find($settings, %params)

Locate the persistent runner for C<$settings> via L<App::Yath2::Discovery/find>
and wrap it in an instance, or return nothing when no live runner was found (a
dangling/dead symlink is cleaned up by the discovery layer). C<%params> are
passed straight through to C<< App::Yath2::Discovery->find >>. The legacy
liveness-banner params (C<no_fatal>, C<no_checks>) are accepted and ignored:
discovery now returns nothing for a dead runner rather than warning/dying about a
stale file.

=item path

=item $path = $pfile->path

The path to the discovery symlink.

=item $data = $pfile->data

A compatibility hashref of the discovered runner: C<pid> (from the workdir C<PID>
file), C<dir> (the workdir), and C<pfile_path> (the symlink path). Built and
cached on first use.

=item $dir = $pfile->workdir

=item $dir = $pfile->dir

The persistent runner's working directory.

=item $pid = $pfile->pid

The persistent runner's process id (read from the workdir C<PID> file).

=item $banner = $pfile->describe

The "Found / PID / Dir" banner string used by the C<which>/C<watch> commands.

=back

=cut

sub find ($class, $settings = undef, %params) {
    croak "Settings is a required argument" unless $settings;

    # The old discovery layer signalled a stale runner by warning/dying; the
    # symlink layer simply returns nothing for a dead runner (and cleans the stale
    # symlink). Drop the legacy banner controls so callers keep compiling.
    delete @params{qw/no_fatal no_warn no_checks/};

    my $discovery = App::Yath2::Discovery->find($settings, %params) or return;

    return $class->new(discovery => $discovery);
}

sub workdir ($self) { return $self->{+DISCOVERY}->workdir }
sub dir     ($self) { return $self->{+DISCOVERY}->workdir }
sub pid     ($self) { return $self->{+DISCOVERY}->pid }
sub path    ($self) { return $self->{+DISCOVERY}->link }

sub data ($self) {
    return $self->{+DATA} //= {
        pid        => $self->{+DISCOVERY}->pid,
        dir        => $self->{+DISCOVERY}->workdir,
        pfile_path => $self->{+DISCOVERY}->link,
    };
}

sub describe ($self) { return $self->{+DISCOVERY}->describe }

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

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

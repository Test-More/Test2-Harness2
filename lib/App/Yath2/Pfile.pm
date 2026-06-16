package App::Yath2::Pfile;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use App::Yath2::Util qw/find_pfile/;
use Test2::Harness2::Util::File::JSON();

use Test2::Harness2::Util::HashBase qw{
    <path
    +data
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Pfile - Reader for a persistent runner's C<yath-persist.json> file.

=head1 DESCRIPTION

A persistent runner records how to reach it in a C<yath-persist.json> "pfile":
its pid, its working directory, and the host/user/version that started it. Every
command that talks to (or merely locates) a persistent runner --
C<run>/C<spawn>/C<stop>/C<which>/C<watch>/C<reload> -- needs to find that file,
read it, and pull the pid and workdir back out of it.

This class is the one shared consumer of that file. L</find> wraps
L<App::Yath2::Util/find_pfile> (which performs the host/user/version/pid
liveness checks) to locate the pfile for the current settings; an instance then
reads the JSON lazily and exposes the pid and workdir. It replaces the half-dozen
near-identical re-reads that previously lived inline in each persistent command.

=head1 SYNOPSIS

    use App::Yath2::Pfile;

    # Locate the persistent runner for the current settings (fatal if the
    # liveness checks fail, like the old run/spawn path):
    my $pfile = App::Yath2::Pfile->find($settings)
        or die "No persistent harness was found for the current path.\n";

    # Or non-fatal, like which/watch/stop/reload:
    my $pfile = App::Yath2::Pfile->find($settings, no_fatal => 1)
        or do { print "No persistent harness ...\n"; return 0 };

    print $pfile->describe;    # the "Found / PID / Dir" banner
    my $dir = $pfile->workdir;
    my $pid = $pfile->pid;

=head1 PUBLIC METHODS

=over 4

=item find

=item $pfile = App::Yath2::Pfile->find($settings, %params)

Locate the pfile for C<$settings> via L<App::Yath2::Util/find_pfile> and wrap it
in an instance, or return nothing if no pfile was found. C<%params> are passed
straight through to C<find_pfile> (e.g. C<< no_fatal => 1 >>,
C<< vivify => 1 >>), so the liveness-check behavior is unchanged from calling
C<find_pfile> directly.

=item path

=item $path = $pfile->path

The path to the pfile.

=item $data = $pfile->data

The decoded pfile contents (a hashref of C<pid>, C<dir>, C<version>, C<user>,
C<hostname>). Read (and cached) on first use. C<pfile_path> is filled in with
L</path> if the file did not carry it, matching the old C<run> behavior.

=item $dir = $pfile->workdir

=item $dir = $pfile->dir

The persistent runner's working directory (the C<dir> field).

=item $pid = $pfile->pid

The persistent runner's process id (the C<pid> field).

=item $banner = $pfile->describe

The "Found / PID / Dir" banner string used by the C<which>/C<watch> commands.

=back

=cut

sub find ($class, $settings = undef, %params) {
    croak "Settings is a required argument" unless $settings;

    my $path = find_pfile($settings, %params) or return;

    return $class->new(path => $path);
}

sub data ($self) {
    return $self->{+DATA} if $self->{+DATA};

    my $data = Test2::Harness2::Util::File::JSON->new(name => $self->{+PATH})->read();
    $data->{pfile_path} //= $self->{+PATH};

    return $self->{+DATA} = $data;
}

sub workdir ($self) { return $self->data->{dir} }
sub dir     ($self) { return $self->data->{dir} }
sub pid     ($self) { return $self->data->{pid} }

sub describe ($self) {
    my $data = $self->data;
    return "\nFound: $self->{+PATH}\n"
        . "  PID: $data->{pid}\n"
        . "  Dir: $data->{dir}\n"
        . "\n";
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

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

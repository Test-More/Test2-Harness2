package Test2::Harness2::Launcher::Win32;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Cwd qw/getcwd/;

use Object::HashBase qw{
    +name
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Launcher';

sub name { $_[0]->{+NAME} //= 'win32' }

sub launch {
    my ($self, $spec) = @_;
    croak "spec must be a hashref" unless ref($spec) eq 'HASH';

    my $exec = $spec->{exec}
        or return (ok => 0, error => "spec is missing 'exec'", temporary => 0);
    return (ok => 0, error => "exec must be an arrayref", temporary => 0)
        unless ref($exec) eq 'ARRAY';
    return (ok => 0, error => "exec is empty", temporary => 0)
        unless @$exec;

    my $cwd_before;
    if (defined $spec->{cwd}) {
        $cwd_before = getcwd();
        chdir($spec->{cwd})
            or return (ok => 0, error => "chdir($spec->{cwd}) failed: $!", temporary => 0);
    }

    local %ENV = %ENV;
    if (my $env = $spec->{env}) {
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    my $pid = system(1, @$exec);

    chdir($cwd_before) if defined $cwd_before;

    return (ok => 0, error => "system(1, ...) returned no pid (got '$pid')", temporary => 0)
        unless $pid && $pid > 0;

    return (ok => 1, pid => $pid);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Launcher::Win32 - Windows launcher (best-effort,
untested in CI on POSIX hosts).

=head1 DESCRIPTION

Windows analogue of L<Test2::Harness2::Launcher::ForkExec>. Same role,
same contract; the only difference is C<launch>, which uses Perl's
C<system(1, @argv)> form. On Windows that returns the spawned process
pid without waiting. On POSIX hosts it does not, and this launcher
should not be used outside Windows.

L<Test2::Harness2::Launcher::Default> picks between this class and
L<Test2::Harness2::Launcher::ForkExec> at construction based on
C<$^O>, so callers normally do not name this class directly.

=head1 ATTRIBUTES

=over 4

=item name

Short identifier, defaults to C<'win32'>.

=back

=head1 PUBLIC METHODS

=over 4

=item %reply = $l->launch(\%spec)

Spawn the requested process via C<system(1, @{$spec->{exec}})>.
Honors C<spec.cwd> and C<spec.env> via temporary C<chdir> and a
C<local %ENV> wrap. On success returns C<(ok =E<gt> 1, pid =E<gt> $pid)>;
on failure returns C<(ok =E<gt> 0, error =E<gt> $reason, temporary =E<gt> 0)>.

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

package Test2::Harness2::Launcher::Win32;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Cwd qw/getcwd/;

use Object::HashBase qw{
    <handle
    <launcher_id
    +scheduler_pid
    +stopping
    +_launcher_children
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Launcher';

sub start_process {
    my ($self, $spec) = @_;
    croak "spec must be a hashref" unless ref($spec) eq 'HASH';

    my $exec = $spec->{exec}
        or croak "spec is missing 'exec'";
    croak "exec must be an arrayref" unless ref($exec) eq 'ARRAY';
    croak "exec is empty" unless @$exec;

    my $cwd_before;
    if (defined $spec->{cwd}) {
        $cwd_before = getcwd();
        chdir($spec->{cwd}) or croak "chdir($spec->{cwd}) failed: $!";
    }

    local %ENV = %ENV;
    if (my $env = $spec->{env}) {
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    my $pid = system(1, @$exec);

    chdir($cwd_before) if defined $cwd_before;

    croak "system(1, ...) returned no pid (got '$pid')"
        unless $pid && $pid > 0;

    return $pid;
}

sub import {
    my ($class, @tags) = @_;
    return unless grep { $_ eq 'start' } @tags;
    require Test2::Harness2::Launcher::EntryPoint;
    Test2::Harness2::Launcher::EntryPoint::install_start_hook($class);
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Launcher::Win32 - Windows launcher (best-effort,
untested in CI on POSIX hosts).

=head1 DESCRIPTION

Windows analogue of L<Test2::Harness2::Launcher::ForkExec>. Same
launcher contract; the only difference is L</start_process>, which
uses Perl's C<system(1, @argv)> form. On Windows that returns the
spawned process pid without waiting. On POSIX hosts it does not,
and this launcher should not be used outside Windows.

The Default launcher (L<Test2::Harness2::Launcher::Default>) picks
between this class and L<Test2::Harness2::Launcher::ForkExec> at
construction based on C<$^O>, so callers normally do not name this
class directly.

=head1 ATTRIBUTES

Same as L<Test2::Harness2::Launcher::ForkExec/ATTRIBUTES>.

=head1 PUBLIC METHODS

=over 4

=item $pid = $l->start_process(\%spec)

Spawn the requested process via C<system(1, @{$spec->{exec}})>.
Honors C<spec.cwd> and C<spec.env> via temporary C<chdir> and a
C<local %ENV> wrap. Returns the spawned process's pid.

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

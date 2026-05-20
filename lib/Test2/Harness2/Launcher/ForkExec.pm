package Test2::Harness2::Launcher::ForkExec;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX ();

use Test2::Harness2::Util::JSON qw/decode_json/;

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

    my $cwd = $spec->{cwd};
    my $env = $spec->{env};

    my $pid = fork // die "fork: $!";
    return $pid if $pid;

    $self->_run_child($exec, $cwd, $env);
    exit 255;
}

sub _run_child {
    my ($self, $exec, $cwd, $env) = @_;

    if (defined $cwd) {
        chdir($cwd) or do {
            print STDERR "ForkExec: chdir($cwd) failed: $!\n";
            POSIX::_exit(254);
        };
    }

    if ($env && ref($env) eq 'HASH') {
        $ENV{$_} = $env->{$_} for keys %$env;
    }

    { exec(@$exec) }
    print STDERR "ForkExec: exec(@$exec) failed: $!\n";
    POSIX::_exit(253);
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

Test2::Harness2::Launcher::ForkExec - POSIX fork+exec launcher.

=head1 DESCRIPTION

The default launcher on every POSIX-y platform. Consumes
L<Test2::Harness2::Role::Launcher>; the only launcher-specific
piece is L</start_process>, which uses C<fork> + C<exec> to start
the requested command. The collector is the immediate child of
this launcher process and the launcher reaps it directly when it
exits.

The C<exec>'d command is whatever the caller put in C<spec.exec>.
In the scheduler-driven path that is the standard collector
entry-point invocation (C<perl -MTest2::Harness2::Collector=start
-e '1;'> with the collector spec fed in over a pipe), but the
launcher does not enforce that shape -- any argv list works, which
is what makes the launcher unit-testable in isolation.

=head1 SYNOPSIS

    use Test2::Harness2::Launcher::ForkExec;

    my $l = Test2::Harness2::Launcher::ForkExec->new(
        handle      => $harness_handle,
        launcher_id => $launcher_row->launcher_id,
    );

    $l->run;   # loop until stopping is set and no children remain

To start the launcher as a fresh process:

    perl -MTest2::Harness2::Launcher::ForkExec=start -e '1;'

The C<=start> import installs an end-of-compile hook that reads a
launcher spec from STDIN and calls the launcher's C<run> method.

=head1 ATTRIBUTES

=over 4

=item handle (required)

The L<Test2::Harness2> handle for database access.

=item launcher_id (required)

The C<launchers.launcher_id> this launcher polls for.

=item scheduler_pid

Optional pid for C<SIGUSR1> wake-ups on each completion.

=item stopping

Set true to ask the launcher to refuse new launches and exit once
in-flight children are reaped.

=back

=head1 PUBLIC METHODS

=over 4

=item $pid = $l->start_process(\%spec)

C<%spec> keys understood by this launcher:

=over 4

=item exec => \@argv (required)

The argv list to C<exec>.

=item cwd => $path

C<chdir> into this directory before C<exec>.

=item env => \%vars

Set these env vars before C<exec>.

=back

Returns the child pid.

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

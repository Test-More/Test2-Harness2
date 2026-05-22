package Test2::Harness2::Launcher::ForkExec;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Errno qw/EAGAIN ENOMEM/;
use POSIX ();

use Object::HashBase qw{
    +name
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Launcher';

sub name { $_[0]->{+NAME} //= 'forkexec' }

sub launch {
    my ($self, $spec) = @_;
    croak "spec must be a hashref" unless ref($spec) eq 'HASH';

    my $exec = $spec->{exec}
        or return (ok => 0, error => "spec is missing 'exec'", temporary => 0);
    return (ok => 0, error => "exec must be an arrayref", temporary => 0)
        unless ref($exec) eq 'ARRAY';
    return (ok => 0, error => "exec is empty", temporary => 0)
        unless @$exec;

    my $cwd = $spec->{cwd};
    my $env = $spec->{env};

    my $pid = fork;
    if (!defined $pid) {
        my $err = "$!";
        my $temporary = ($!{EAGAIN} || $!{ENOMEM}) ? 1 : 0;
        return (ok => 0, error => "fork: $err", temporary => $temporary);
    }

    return (ok => 1, pid => $pid) if $pid;

    $self->_run_child($exec, $cwd, $env);
    POSIX::_exit(255);
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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Launcher::ForkExec - POSIX fork+exec launcher.

=head1 DESCRIPTION

The default launcher on every POSIX-y platform. Consumes
L<Test2::Harness2::Role::Launcher>; an in-process object owned by the
scheduler. Its C<launch> does C<fork> + C<exec> in the caller's
process, so the resulting collector is a direct child of whoever
called C<launch> (in normal use, the scheduler).

=head1 SYNOPSIS

    use Test2::Harness2::Launcher::ForkExec;

    my $l = Test2::Harness2::Launcher::ForkExec->new(name => 'fe');

    my %reply = $l->launch({
        exec => [$^X, '-MTest2::Harness2::Collector=start', '-e', '1'],
        cwd  => '/some/dir',         # optional
        env  => { FOO => 'bar' },    # optional
    });

    if ($reply{ok}) {
        my $pid = $reply{pid};
        # scheduler reaps $pid in its event loop
    }
    else {
        # $reply{error}, $reply{temporary}
    }

=head1 ATTRIBUTES

=over 4

=item name

Short identifier, defaults to C<'forkexec'>. Used for logging and
for routing when several launchers share a scheduler.

=back

=head1 PUBLIC METHODS

=over 4

=item %reply = $l->launch(\%spec)

C<%spec> keys understood by this launcher:

=over 4

=item exec => \@argv (required)

The argv list to C<exec>.

=item cwd => $path

C<chdir> into this directory before C<exec>.

=item env => \%vars

Set these env vars before C<exec>.

=back

On success returns C<(ok =E<gt> 1, pid =E<gt> $pid)>. On failure
returns C<(ok =E<gt> 0, error =E<gt> $reason, temporary =E<gt> 0|1)>;
C<fork> failures with C<EAGAIN> / C<ENOMEM> are classified
temporary, everything else (bad spec, etc.) is permanent.

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

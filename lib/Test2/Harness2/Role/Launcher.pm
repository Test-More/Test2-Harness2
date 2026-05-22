package Test2::Harness2::Role::Launcher;
use strict;
use warnings;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'name';
requires 'launch';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Launcher - Contract role implemented by every
launcher.

=head1 DESCRIPTION

Launchers are plain in-process objects owned by the scheduler. They
are B<not> services -- this role does B<not> consume
L<Test2::Harness2::Role::Service>, has no poll loop, and does no
database work of its own.

A launcher's job is to start one collector + collected-process pair
when the scheduler calls C<launch(\%spec)>. The role declares only the
two methods every launcher must provide; everything else (the
fork+exec mechanics, the choice of platform implementation, the
proxy-over-socket protocol for preload launchers, etc.) is the
implementation's concern.

See C<ARCHITECTURE.md> section 7 for the full design.

=head1 REQUIRED METHODS

=over 4

=item $name = $launcher->name

A short identifier the launcher answers to. Used for logging and for
routing requests when more than one launcher is configured.

=item %reply = $launcher->launch(\%spec)

Synchronously start one collector + collected-process pair for the
given spec. C<%reply> is a key/value list:

=over 4

=item ok => 1, pid => $pid

The process was started. C<pid> is present only for launchers whose
C<launch> forks in the caller's process (the regular in-process
launchers); proxy launchers that hand the request off to a separate
service return C<ok =E<gt> 1> without a pid -- the collector itself
writes its row to the database in that case.

=item ok => 0, error => $reason, temporary => 0 | 1

The launch failed. The scheduler interprets C<temporary> as follows:
true means "try again on a future loop"; false means "fail this
job_try with this reason and do not retry on this launcher."

=back

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

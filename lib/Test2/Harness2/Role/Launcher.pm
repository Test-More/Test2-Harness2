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

A launcher's job is to wrap a test process in a collector and start
the pair when the scheduler calls C<launch($job_try)>. The launcher
reads everything it needs off the C<job_tries> row (and its related
C<job> row through the harness handle); the scheduler does not hand
the launcher raw C<exec> argv. See C<ARCHITECTURE.md> section 7.

=head1 REQUIRED METHODS

=over 4

=item $name = $launcher->name

A short identifier the launcher answers to. Used for logging and for
routing requests when more than one launcher is configured.

=item %reply = $launcher->launch($job_try)

Synchronously start one collector + test process pair for the given
L<Test2::Harness2::DB::JobTry> row. The launcher resolves the related
C<jobs.spec> JSON to find the test file, C<@INC> additions, modules
to load, env vars, and cwd; builds the test argv accordingly; wraps
the test in a L<Test2::Harness2::Collector> by calling C<start> on
the collector with the launcher's parser / auditor / recorder
configuration; and returns the collector's pid.

C<%reply> is a key/value list:

=over 4

=item ok => 1, pid => $collector_pid

The collector started. C<pid> is the OS pid of the B<collector
process>, which is itself the immediate parent of the test process
(see C<ARCHITECTURE.md> section 5.1). C<pid> is set only for launchers
whose C<launch> forks in the caller's process (the regular in-process
launchers); proxy launchers that hand the request off to a separate
service return C<ok =E<gt> 1> without a pid -- the collector itself
writes its row to the database in that case.

=item ok => 0, error => $reason, temporary => 0 | 1

The launch failed. The scheduler interprets C<temporary> as follows:
true means "try again on a future loop"; false means "fail this
job_try with this reason and do not retry on this launcher."

=back

=back

=head1 JOB SPEC SHAPE

The launcher consumes C<jobs.spec> (decoded JSON) with these documented
keys:

=over 4

=item test_file

Absolute path to the test script.

=item includes

Arrayref of C<@INC> directories. Each becomes a C<-I> arg on the test
argv.

=item modules

Arrayref of module names. Each becomes a C<-M> arg on the test argv.

=item env

Hashref of env vars set in the test process before C<exec>.

=item cwd

Optional working directory for the test process.

=back

Per-launcher knobs (parser class, auditor class, recorder, default
timeouts) live on the launcher object itself -- they are set when the
scheduler constructs the launcher at startup, not on the C<job_try>.

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

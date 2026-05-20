package Test2::Harness2::Collector::Role::Recorder;
use strict;
use warnings;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'record_event';
requires 'record_state';
requires 'record_exit';
requires 'record_artifact';
requires 'finalize';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Role::Recorder - Role implemented by collector recorders.

=head1 DESCRIPTION

Recorders are the sink of the collector pipeline. They are the only objects
in the pipeline that may own a database handle: parsers, auditors, and the
collector core itself route every write through one of the methods listed
below.

Two recorders ship in Part 1:

=over 4

=item L<Test2::Harness2::Collector::Recorder::Files>

Plain on-disk recorder, no database. Used by C<t/scripts/collector> and by
integration tests that exercise the collector pipeline without standing up
a database.

=item L<Test2::Harness2::Collector::Recorder::DB>

Database-backed recorder. Writes the C<collectors> row at startup, captures
the event stream as an C<artifacts> blob (compressed bursts pass through
intact), and migrates external files (screenshots, etc.) from C<local_path>
into C<content> on finalize.

=back

=head1 REQUIRED METHODS

=over 4

=item $recorder->record_event($event)

Append a single L<Test2::Harness2::Event> to the event stream. Recorders
that handle the wire bytes specially (zstd pass-through) may inspect the
event's C<compressed_form> slot when present.

=item $recorder->record_state($state, $extra)

Record a state transition for the watched process. C<$state> is a short
identifier (C<'starting'>, C<'running'>, C<'failing'>, C<'completed'>,
etc.); C<$extra> is an optional hashref of state-specific detail.

=item $recorder->record_exit($exit, \%info)

Record the exit code of the collected process. C<$exit> is the raw
wait-status (as returned by C<wait>); recorders may decode it via
L<Test2::Harness2::Util::IPC/parse_exit> as needed.

C<%info> is an optional hashref of out-of-band flags discovered at
collection time. Currently defined:

=over 4

=item orphaned => $bool

True when the collector reaped the collected process but its pipes
stayed open past the orphan-timeout, indicating descendants outlived
the parent. The recorder is expected to surface this so downstream
consumers (the row layer's job-try record, etc.) can flag the
condition. The flag is informational; it does not turn a pass into
a fail.

=back

=item $recorder->record_artifact(\%spec)

Record an external artifact (screenshot, dump file, etc.). C<%spec>
carries at least a C<name> and either a C<local_path> or C<content>.
Recorders decide whether to migrate C<local_path> bytes into C<content>
at finalize.

=item $recorder->finalize()

Close any open files, set the C<finalized> flag on the recorder's
collector row (or its on-disk equivalent), and release resources. After
C<finalize> the recorder must not accept further writes.

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

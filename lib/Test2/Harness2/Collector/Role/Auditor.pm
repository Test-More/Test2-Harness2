package Test2::Harness2::Collector::Role::Auditor;
use strict;
use warnings;

our $VERSION = '2.000000';

use Role::Tiny;

requires 'audit_event';
requires 'fail_count';
requires 'pass_count';

sub passing { !$_[0]->fail_count }
sub failing { $_[0]->fail_count }

sub startup  { () }
sub shutdown { () }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Role::Auditor - Role implemented by collector auditors.

=head1 DESCRIPTION

Auditors sit between the parser and the recorder. Every event the parser
produces is handed to C<audit_event>; the auditor inspects the event,
updates its own state (assertion count, plan, halt status, etc.), and
returns zero or more events for the recorder to write.

Only test-job collectors install an auditor. Service collectors run without
one.

=head1 REQUIRED METHODS

=over 4

=item @events = $auditor->audit_event($event)

Inspect C<$event> (a L<Test2::Harness2::Event>), update internal state, and
return zero or more events for the recorder. The returned list may contain
the original event, a transformed event, or freshly synthesized events
(subtest announcements, plan/count mismatches, recovery-from-malformed-TAP
notes, etc.). Returning an empty list drops the event from the pipeline.

=item $n = $auditor->fail_count()

Return the number of failures the auditor has counted so far.

=item $n = $auditor->pass_count()

Return the number of passing assertions the auditor has counted so far.

=back

=head1 PROVIDED METHODS

=over 4

=item $bool = $auditor->passing()

True when C<fail_count> is zero. Override if richer state (intermediate,
ambiguous) is needed.

=item $bool = $auditor->failing()

True when C<fail_count> is non-zero. Override alongside C<passing>.

=item @events = $auditor->startup()

Lifecycle hook called once by the collector before the first event is
audited. Returns zero or more events. Default: empty list.

=item @events = $auditor->shutdown()

Lifecycle hook called once after the collected process exits, so the
auditor can emit final synthetic events (final plan / count mismatch
diagnostics, etc.). Returns zero or more events. Default: empty list.

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

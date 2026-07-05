package App::Yath2::Renderer::ResetTerm;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Renderer';
use Test2::Harness2::Util::HashBase;

# Package-level latch: true once the terminal has been reset (either via a clean
# finish() or the END-block fallback). Guards against a double reset on the
# normal path. Package-scoped (not per-instance) so the END block can see whether
# any instance already reset, and so it works even if the instance is gone.
my $RESET_DONE = 0;

# Emit the terminal reset: clear attributes (color/bold/etc. a misbehaving test
# may have left set) and show the cursor (in case a test hid it). Only when
# STDOUT is a real terminal -- a no-op when piped/redirected. Idempotent via the
# package latch.
sub _reset_term {
    return if $RESET_DONE;
    $RESET_DONE = 1;
    return unless -t STDOUT;
    print "\e[0m\e[?25h";
    return;
}

# render_event is intentionally a no-op: this renderer only exists for its
# finish() side effect (and the END-block fallback). It consumes no events.
sub render_event {}

# Normal teardown path: the command's stop()/finish() fan-out calls this last
# (ResetTerm is injected last into the renderer list), so the reset is the final
# thing printed after every other renderer has flushed.
sub finish { $_[0]->_reset_term }

# Abnormal-exit safety net: on Ctrl-C / panic / die the command may never reach
# its finish() fan-out, leaving the terminal in a weird state. This END block
# still restores it. It does NOT install a signal handler -- the harness owns
# signals; this is purely the process-exit fallback. Idempotent with finish()
# via the package latch.
END { __PACKAGE__->_reset_term }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::ResetTerm - Renderer that restores the terminal on exit.

=head1 DESCRIPTION

A no-op renderer whose only job is to undo terminal state (color/attribute and
cursor-visibility changes) that a misbehaving test may leave behind. It renders
no events; on C<finish()> (and via an C<END>-block fallback for abnormal exits)
it prints C<\e[0m\e[?25h> -- reset attributes and show the cursor -- but only
when C<STDOUT> is a terminal, so it is a no-op when output is piped or
redirected.

It is auto-injected last into the renderer list when C<STDOUT> is a TTY, so the
reset is the final output after every other renderer has flushed. It installs no
signal handler -- the harness owns signals; the C<END>-block is the
abnormal-exit safety net.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness2/>.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

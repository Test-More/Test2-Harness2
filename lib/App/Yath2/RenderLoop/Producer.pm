package App::Yath2::RenderLoop::Producer;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

requires qw/poll done/;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::RenderLoop::Producer - Role for a pure render-loop event source.

=head1 DESCRIPTION

A B<Producer> is the pure source half of the render-loop library
(L<App::Yath2::RenderLoop>): it yields the ordered events the loop should render
and reports when the source is exhausted. It does B<not> dispatch events, write
the log, run plugins, or compute the run rollup -- those are the loop's job. This
split lets one loop render a live run, a flat event log, or (later) an archived
database log just by swapping the producer.

Concrete producers compose this role and implement:

=over 4

=item @events = $producer->poll

Advance the source and return the next batch of ready-to-render events in the
order they should be rendered (possibly empty when nothing new is ready yet). The
loop dispatches whatever is returned and then re-checks C<done>.

=item $bool = $producer->done

True once the source is exhausted and C<poll> will not yield anything more (the
runner closed its socket / the run announced its end / the log hit EOF). The loop
keeps polling until this is true.

=back

=head1 OPTIONAL METHODS

=over 4

=item @events = $producer->finalize

If implemented, called once after C<done> becomes true: a last chance to flush
any held-back events (e.g. a final sweep of completed-but-unrendered jobs). The
loop dispatches whatever is returned. Producers that need no final flush may omit
it.

=back

=cut

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

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

See F<http://dev.perl.org/licenses/>

=cut

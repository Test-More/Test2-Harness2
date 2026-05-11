package Test2::Harness2::Role::Reloader;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Role::Tiny;

# Role::Reloader -- contract for the reloader subsystem.
#
# A reloader is an object plugged into a long-lived PreloadService that
# watches for source changes under the project root and decides what to
# do when one fires:
#
#   - in-place reload of a single file (default; cheap; survives module
#     state held outside %INC),
#   - flip the resource to transient broken when a reload errors,
#   - restart the whole service (exec) when an in-place reload isn't
#     safe (structural / role / inheritance changes).
#
# Required methods:
#
#   watch_paths()
#     Returns the set of directories the reloader monitors. Implementations
#     return an arrayref of absolute paths. The default (in
#     Test2::Harness2::Reloader::Common) is the project root walked from
#     cwd, but a consumer can override.
#
#   do_reload($svc)
#     Drive one reloader tick. Called from PreloadService's per-interval
#     hook. Returns nothing; side-effects are emit_service_event /
#     IPC messages.
#
# Optional defaults (overridable):
#
#   debounce_secs()     Floor on the interval between two consecutive
#                       reloads. Defaults to 0.25.
#   before_reload($svc, $file)
#                       Hook fired in the service process before a single
#                       in-place reload begins. Default: no-op.
#   after_reload($svc, $file, $ok, $err)
#                       Hook fired after the in-place reload completes
#                       (succeeded or not). Default: no-op.

requires 'watch_paths';
requires 'do_reload';

sub debounce_secs { 0.25 }

sub before_reload { }
sub after_reload  { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Reloader - Contract for reloader implementations.

=head1 SYNOPSIS

    package Test2::Harness2::Reloader::HiResStat;
    use strict;
    use warnings;

    use parent 'Test2::Harness2::Reloader::Common';
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Reloader';

    sub watch_paths { ... }
    sub do_reload   { ... }

    1;

=head1 DESCRIPTION

Implementations of this role plug into a PreloadService and watch the
project's source tree for changes. The role specifies only the
contract; the shared reload logic lives in
L<Test2::Harness2::Reloader::Common> (project root discovery, %INC
filtering, in-place reload, request_restart).

Required:

=over 4

=item watch_paths

Return an arrayref of absolute directories to monitor.

=item do_reload($svc)

Called from PreloadService's per-interval hook. One tick of the
reloader's poll / event loop.

=back

Optional (defaults supplied by this role):

=over 4

=item debounce_secs

Minimum interval between two consecutive reloads. Default 0.25s.

=item before_reload($svc, $file)

Fired in the service process before an in-place reload begins.

=item after_reload($svc, $file, $ok, $err)

Fired after the in-place reload completes. C<$ok> is truthy on
success; C<$err> carries the load error otherwise.

=back

=cut

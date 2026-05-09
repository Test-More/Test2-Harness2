package App::Yath2::Role::EventIterator;
use strict;
use warnings;

our $VERSION = '2.000012';

use Role::Tiny;

# The contract every yath event-iterator consumes. Today implemented by
# App::Yath2::DB::Iterator (depth-first walker over an archive's
# events.jsonl streams) and App::Yath2::Log::Iterator::JSONL (single-
# file JSONL reader used by the per-artifact events_iter / spec_iter /
# report_iter helpers).
#
# Required surface:
#
#     $event = $iter->next;     # next decoded record, or undef when drained
#     $bool  = $iter->EOE;      # true once the iterator can yield nothing more
#     $iter->reset;             # rewind to the beginning
#     $n     = $iter->count;    # total number of records the iterator will yield
#
# Provided helpers below:
#
#     @events = $iter->all;     # drain to a list via while-next
#     $first  = $iter->first;   # reset + return the first record

requires qw{ next EOE reset count };

sub all {
    my $self = shift;
    my @out;
    while (defined(my $e = $self->next)) {
        push @out, $e;
    }
    return @out;
}

sub first {
    my $self = shift;
    $self->reset;
    return $self->next;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::EventIterator - Contract for yath event iterators.

=head1 DESCRIPTION

Every yath event iterator -- whether it walks a sealed DB archive
(L<App::Yath2::DB::Iterator>) or reads a single jsonl file
(L<App::Yath2::Log::Iterator::JSONL>) -- consumes this role. The role
fixes the public surface so callers can swap one for the other without
caring which produced the events.

=head1 SYNOPSIS

    package My::Iterator;
    use Object::HashBase qw{...};

    use Role::Tiny::With;
    with 'App::Yath2::Role::EventIterator';

    sub next  { ... }
    sub EOE   { ... }
    sub reset { ... }
    sub count { ... }

    # ->all and ->first are provided by the role.

=head1 REQUIRED METHODS

=over 4

=item $event = $iter->next

Return the next decoded event, or undef when the iterator is drained.

=item $bool = $iter->EOE

True once the iterator will yield no further events.

=item $iter->reset

Rewind to the first event.

=item $n = $iter->count

Total number of events the iterator will yield. Implementations may
cache the result; callers may invoke it before, during, or after
draining.

=back

=head1 PROVIDED METHODS

=over 4

=item @events = $iter->all

Drain the iterator into a list via a C<while ($iter->next)> loop.

=item $event = $iter->first

Call C<reset> then C<next>; convenience for callers that want record
zero of a possibly-already-walked iterator.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

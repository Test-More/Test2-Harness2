package Test2::Harness2::Role::Resource::Assignable;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Harness2::Util::HiResTime qw/hi_res_time/;

use Role::Tiny;

# Constants for the two hash slots this role reads/writes. Consumers
# that declare matching Object::HashBase slots (named 'assignments'
# and 'paused') already define same-valued constants; Role::Tiny
# composition leaves the consumer's versions in place. Inside this
# role the +ASSIGNMENTS / +PAUSED tokens resolve at compile time
# against the role's own constants, so the slot key strings are baked
# in regardless of composition order.
use constant ASSIGNMENTS => 'assignments';
use constant PAUSED      => 'paused';

# Resources that maintain a flat $self->{assignments} hash keyed by
# assignment id pick up assign / release / pause-state bookkeeping
# from this role instead of duplicating the same six methods. The
# subset of resources whose contract is exactly "one assignment slot
# per id, no per-job math beyond storing the job + timestamp" use
# the role; resources with bespoke assign semantics (none currently)
# would skip it.

sub is_paused    { $_[0]->{+PAUSED} ? 1 : 0 }
sub mark_paused  { $_[0]->{+PAUSED} = 1 }
sub mark_resumed { $_[0]->{+PAUSED} = 0 }

sub assign {
    my ($self, %p) = @_;

    my $id  = $p{id}  or croak "'id' is required";
    my $job = $p{job} or croak "'job' is required";
    croak "'env' hashref is required" unless ref($p{env}) eq 'HASH';

    croak ref($self) . ": duplicate assign for id '$id'"
        if exists $self->{+ASSIGNMENTS}->{$id};

    $self->{+ASSIGNMENTS}->{$id} = {job => $job, assigned_at => hi_res_time()};

    return 1;
}

sub release {
    my ($self, %p) = @_;

    my $id = $p{id} or croak "'id' is required";

    delete $self->{+ASSIGNMENTS}->{$id}
        or croak ref($self) . ": invalid release id '$id'";

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Resource::Assignable - Shared assignment-map bookkeeping for simple resources.

=head1 DESCRIPTION

Resources that satisfy the C<Test2::Harness2::Role::Resource> contract
with a flat per-id assignment map -- one record per in-flight
assignment, the record holds the job and a wall-clock timestamp, and
nothing else -- can consume this role to inherit the boilerplate
implementations of:

=over 4

=item *

C<assign> / C<release>: validate C<id>, C<job>, and C<env>; reject
duplicate-id assigns and unknown-id releases; on success store
C<< { job => $job, assigned_at => hi_res_time() } >> under
C<< $self->{assignments}{$id} >>.

=item *

C<is_paused> / C<mark_paused> / C<mark_resumed>: simple boolean
toggle stored at C<< $self->{paused} >>.

=back

The role exposes C<ASSIGNMENTS> and C<PAUSED> constants whose values
are the lowercase strings C<'assignments'> and C<'paused'>. Consumers
that allocate matching L<Object::HashBase> slots -- naming them
C<assignments> and C<paused> -- get same-valued constants of their
own, and the methods read/write the same hash slots in either
direction. Resources that override any of the above (e.g. Disk's
bespoke C<mark_resumed> that preserves a permanent-broken flag) keep
their own implementation; Role::Tiny lets the consumer's method win.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

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

See L<https://dev.perl.org/licenses/>

=cut

package Test2::Harness2::Resource::Preload;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Object::HashBase qw{
    <name
    <modules
    <scope
    <run
    <is_role_consumer
    +_usable
    +_broken
    +_permanent_broken
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

sub init {
    my $self = shift;

    croak "'name' is a required attribute"
        unless defined $self->{+NAME} && length $self->{+NAME};
    croak "'modules' is a required attribute (arrayref, may be empty)"
        unless defined $self->{+MODULES} && ref($self->{+MODULES}) eq 'ARRAY';

    $self->{+SCOPE}            //= 'global';
    $self->{+IS_ROLE_CONSUMER} //= 0;
    $self->{+_USABLE}            = 0;
    $self->{+_BROKEN}            = 0;
    $self->{+_PERMANENT_BROKEN}  = 0;

    croak "'scope' must be 'global' or 'run'"
        unless $self->{+SCOPE} eq 'global' || $self->{+SCOPE} eq 'run';
    croak "scope='run' requires 'run'"
        if $self->{+SCOPE} eq 'run' && !ref($self->{+RUN});
}

sub resource_name { 'preload:' . $_[0]->{+NAME} }

# Routing decision lives in the harness's resolver
# (_resolve_preload_for_job), NOT in the scheduler's normal needs-this-
# resource walk. Returning 0 here keeps _evaluate_resources_for from
# selecting a preload on its own; the scheduler injects the resolved
# Resource::Preload alongside the rest of the assigned resources after
# the resolver picks one.
sub needed { 0 }

# Always available -- the yes/no decision is "is the service ready",
# which is_usable answers. No slot accounting.
sub available { 1 }

# Pure markers; the assignment IS routing, not slot consumption. No
# env vars set.
sub assign  { return 1 }
sub release { return 1 }

sub status {
    my $self = shift;
    return {
        name              => $self->{+NAME},
        scope             => $self->{+SCOPE},
        usable            => $self->{+_USABLE} ? 1 : 0,
        broken            => $self->{+_BROKEN} ? 1 : 0,
        permanent_broken  => $self->{+_PERMANENT_BROKEN} ? 1 : 0,
        is_role_consumer  => $self->{+IS_ROLE_CONSUMER} ? 1 : 0,
        modules           => [@{$self->{+MODULES}}],
        ($self->{+SCOPE} eq 'run' && ref($self->{+RUN})
            ? (run_id => $self->{+RUN}->run_id)
            : ()),
    };
}

# Role::Resource defaults return 0; override here so the harness can
# read state through the standard accessors.
sub is_broken           { $_[0]->{+_BROKEN} ? 1 : 0 }
sub is_permanent_broken { $_[0]->{+_PERMANENT_BROKEN} ? 1 : 0 }
sub is_paused           { 0 }

# Override the role default. The role returns true unless something
# is wrong; for preload we additionally require the service to have
# signalled ready. The service is considered "not yet ready" until
# its preload_ready IPC arrives, even with no broken flags set.
sub is_usable {
    my $self = shift;
    return 0 if $self->{+_BROKEN};
    return 0 if $self->{+_PERMANENT_BROKEN};
    return $self->{+_USABLE} ? 1 : 0;
}

# State transitions driven by harness side in response to preload_*
# IPC events. mark_ready is the only way out of transient broken;
# permanent_broken is sticky (no cleanup path) so a per-run
# preload_ready can never clear a global preload's permanent_broken
# flag (and vice versa). See AI_DOCS/2026-05-10-preload-rework-design.md
# section 5.
sub mark_ready {
    my $self = shift;
    return if $self->{+_PERMANENT_BROKEN};
    $self->{+_USABLE} = 1;
    $self->{+_BROKEN} = 0;
}

sub mark_unusable {
    my $self = shift;
    $self->{+_USABLE} = 0;
}

sub mark_broken {
    my $self = shift;
    $self->{+_BROKEN} = 1;
    $self->{+_USABLE} = 0;
}

sub mark_permanent_broken {
    my $self = shift;
    $self->{+_PERMANENT_BROKEN} = 1;
    $self->{+_USABLE}           = 0;
}

sub mark_paused  { }
sub mark_resumed { }

# The Resource hosts one PreloadService process. The
# ResourceServiceHost role on the harness picks this up and calls
# its standard spawn pipeline; the service registers in RUN_PIDS
# under the appropriate scope/run.
sub services {
    my $self = shift;

    # Re-exec the preload service via a fresh perl with the boot module
    # loaded. stay_in_begin=1 makes IPC::Manager::Service::State::import
    # run the service loop synchronously at BEGIN time of the spawned
    # perl's -e snippet. That keeps the entry-script parser paused
    # while the service is running, which is the only state in which
    # goto::file can usefully install a source filter -- specifically
    # the filter PreloadService::run installs in the test grandchild
    # after a longjump out of the service loop.
    #
    # @INC is propagated as -I flags on the exec command so the freshly
    # exec'd perl can find the harness modules + every CPAN dep the
    # parent has already located. PERL5LIB would work too but -I avoids
    # interaction with whatever the user's shell has set.
    my @inc = grep { defined && length } @INC;
    my @cmd = map  { "-I$_" } @inc;

    my @args = (
        name             => $self->{+NAME},
        modules          => [@{$self->{+MODULES}}],
        scope            => $self->{+SCOPE},
        is_role_consumer => $self->{+IS_ROLE_CONSUMER} ? 1 : 0,
        ($self->{+SCOPE} eq 'run' && ref($self->{+RUN})
            ? (run_id => $self->{+RUN}->run_id)
            : ()),
        exec => {
            cmd           => \@cmd,
            stay_in_begin => 1,
        },
    );
    return (['Test2::Harness2::PreloadService', @args]);
}

1;

__END__

=pod

=head1 NAME

Test2::Harness2::Resource::Preload - Resource that owns one
PreloadService process.

=head1 DESCRIPTION

A preload bundles a name and a list of perl modules. The harness
spawns a service per Resource::Preload instance; the service
require()s the modules at startup and waits for spawn_test
requests. Tests routed through this resource become collector
grandchildren of the harness via the service's double-fork +
Long::Jump path.

The Resource itself never participates in slot accounting:
available() always returns 1 and assign/release are no-ops. The
yes/no decision for the scheduler is "is the service ready", which
is_usable answers. Three states drive that:

=over 4

=item * usable -- service has emitted preload_ready

=item * transient broken -- reload-restart cycle in progress, or a
reload-compile-error window pending a user fix

=item * permanent broken -- initial-load failure or restart-spiral
cap exceeded; never cleared without a fresh harness invocation

=back

See AI_DOCS/2026-05-10-preload-rework-design.md sections 3, 4, and
5 for the surrounding architecture.

=cut

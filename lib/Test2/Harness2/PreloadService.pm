package Test2::Harness2::PreloadService;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Basename qw/dirname/;

use Object::HashBase qw{
    <preload_name
    <modules
    <scope
    <run_id
    <is_role_consumer
    <log_path
    <ipcm_info
    <workdir
    kill_timeout
    state
    own_pgroup
    watch_pids
    +pid
    +_name
};

use Role::Tiny::With;
# Role::Service transitively consumes Role::ResourceService and
# IPC::Manager::Role::Service, so a single `with` here satisfies the
# host's Role::ResourceService check too.
with 'Test2::Harness2::Role::Service';

sub init {
    my $self = shift;

    # Accept the host's 'name' construction arg as preload_name; the
    # bus-level service name is derived (preload-<name> for global,
    # preload-<run_id>-<name> for run scope) so the scheduler can
    # address a preload by its preload_name + scope tuple while the
    # host-level uniqueness check sees the namespaced name.
    if (defined $self->{name} && !defined $self->{+PRELOAD_NAME}) {
        $self->{+PRELOAD_NAME} = delete $self->{name};
    }

    croak "'name' is a required attribute"
        unless defined $self->{+PRELOAD_NAME} && length $self->{+PRELOAD_NAME};
    croak "'modules' is a required attribute (arrayref, may be empty)"
        unless defined $self->{+MODULES} && ref($self->{+MODULES}) eq 'ARRAY';

    $self->{+SCOPE}            //= 'global';
    $self->{+IS_ROLE_CONSUMER} //= 0;
    $self->{+KILL_TIMEOUT}     //= 15;
    $self->{+STATE}            //= 'running';
    $self->{+WATCH_PIDS}       //= [];
    $self->{+OWN_PGROUP}       //= 0;

    croak "'scope' must be 'global' or 'run'"
        unless $self->{+SCOPE} eq 'global' || $self->{+SCOPE} eq 'run';
    croak "scope='run' requires 'run_id'"
        if $self->{+SCOPE} eq 'run' && !(defined $self->{+RUN_ID} && length $self->{+RUN_ID});

    # workdir defaults to the directory containing log_path; Role::Service
    # surfaces it on the service_started event, no on-disk usage of our
    # own.
    if (!defined $self->{+WORKDIR}) {
        $self->{+WORKDIR} = defined $self->{+LOG_PATH} ? dirname($self->{+LOG_PATH}) : '.';
    }

    # Cache the bus-level name on first read.
    $self->{+_NAME} = $self->_compute_name;
}

sub _compute_name {
    my $self = shift;
    my $pn   = $self->{+PRELOAD_NAME};
    return "preload-$pn" if $self->{+SCOPE} eq 'global';
    return "preload-$self->{+RUN_ID}-$pn";
}

sub name { $_[0]->{+_NAME} //= $_[0]->_compute_name }

# Role::Service emits service_started carrying these extra fields so a
# downstream reader of the resource service's log file can tell which
# preload it is and whether the preload is a Role::Preload consumer.
sub service_started_fields {
    my $self = shift;
    return (
        preload_name     => $self->{+PRELOAD_NAME},
        preload_scope    => $self->{+SCOPE},
        preload_modules  => [@{$self->{+MODULES}}],
        is_role_consumer => $self->{+IS_ROLE_CONSUMER} ? 1 : 0,
        ($self->{+SCOPE} eq 'run' ? (preload_run_id => $self->{+RUN_ID}) : ()),
    );
}

# Minimal stub. Real implementation lands in Task 1.7 once the BEGIN
# block + do_preload + ready emission are in place. At that point this
# will return the pids of any in-flight spawn-in-progress workers.
sub hard_stop_pids {
    my $self = shift;
    return ();
}

# Resource services receive log_path from the host; until the BEGIN
# block lifecycle lands the service has no STDOUT-bound EventEmitter,
# so emit_service_event is a no-op. Task 1.7 wires this up to write
# JSONL into log_path.
sub emit_service_event { }

# Restartability matches Resource::Preload's contract: a clean exit
# flips the resource to permanent_broken so the harness reports the
# preload as gone rather than silently respawning into the same failure.
sub restartable { 0 }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::PreloadService - Long-lived service that pre-loads
modules for a Resource::Preload.

=head1 STATUS

Skeleton. The service composes
L<Test2::Harness2::Role::Service> and
L<Test2::Harness2::Role::ResourceService>, accepts the preload identity
construction parameters that
L<Test2::Harness2::Resource::Preload/services> hands it
(C<name>, C<modules>, C<scope>, C<run_id>, C<is_role_consumer>), and
exposes them through C<service_started_fields>. The C<BEGIN> +
C<do_preload> + spawn-test plumbing lands in later tasks of the
preload-rework plan.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut

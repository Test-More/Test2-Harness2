package Test2::Harness2::Role::Preload;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Harness2::Util qw/mod2file/;

use Role::Tiny;

# Role::Preload — contract for "complex" preloads. A module that
# consumes this role becomes its own named preload service when
# listed on the `yath -P` command line (Options::Preload classifies
# role-consumers separately from anonymous `-P Module` bundles).
#
# Required:
#   name()        Class method. String identifier for this preload.
#                 Used as the Resource::Preload's name and exposed in
#                 service_started_fields as preload_name.
#
# Optional. A consumer may provide any subset. Defaults sit in this
# role; the consumer's overrides win where present.
#
#   modules()        Class or instance method. Returns an arrayref of
#                    module names to load via require during
#                    do_preload. May be empty when the consumer
#                    provides its own do_preload entry that does not
#                    rely on the simple-require path.
#
#   do_preload($svc) Performs the load step. Defaults to a sequential
#                    require of each entry returned by modules(), with
#                    the same diagnostic shape PreloadService uses for
#                    its plain modules list.
#
#   pre_fork($svc, $payload)
#                    Called in the preload service process immediately
#                    before fork()ing to spawn a test. Default: no-op.
#                    Use for cache warm-ups, lazy connection setup,
#                    or anything that should run in the long-lived
#                    parent so the test inherits the side effects.
#
#   post_fork($svc, $payload)
#                    Called in the first child (the soon-to-exit
#                    intermediate process) after fork. Default: no-op.
#                    This child calls POSIX::_exit shortly after; any
#                    work here should be cheap.
#
#   pre_launch($svc, $payload)
#                    Called in the grandchild (the test process)
#                    immediately before the longjump that hands
#                    control to the test file. Default: no-op. Use
#                    for per-test state resets that the standard
#                    Test2 post-preload reset does not cover.
#
# $svc is the live PreloadService instance; $payload is the spawn
# request payload (test_file_abs, run_id, job_id, env, ...).

requires 'name';

sub modules { [] }

sub do_preload {
    my ($self, $svc) = @_;

    my $mods = $self->modules // [];
    croak ref($self) . "->modules must return an arrayref"
        unless ref($mods) eq 'ARRAY';

    for my $mod (@$mods) {
        my $ok  = eval { require( mod2file($mod) ); 1 };
        my $err = $@;
        next if $ok;

        my $name = $self->name;
        chomp(my $e = $err);
        croak "Failed to load module '$mod' for preload '$name': $e";
    }

    return 1;
}

sub pre_fork    { }
sub post_fork   { }
sub pre_launch  { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Preload - Contract for role-based "complex"
preloads.

=head1 SYNOPSIS

    package MyApp::Preload;
    use strict;
    use warnings;

    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Preload';

    sub name    { 'myapp' }
    sub modules { [qw/MyApp::Model MyApp::Schema/] }

    sub pre_fork {
        my ($self, $svc, $payload) = @_;
        # warm a cache in the long-lived service process
    }

    sub pre_launch {
        my ($self, $svc, $payload) = @_;
        # reset per-test state in the test grandchild
    }

    1;

=head1 DESCRIPTION

Consume this role to opt into the C<yath -P> "complex preload"
pathway. The harness builds a dedicated C<Test2::Harness2::Resource::Preload>
for the consuming class (named after C<< $class->name >>) and runs
the consumer's hooks inside the PreloadService's spawn pipeline.

Required:

=over 4

=item name

Class method. Returns the string identifier for this preload.

=back

Optional hooks (defaults in this role):

=over 4

=item modules

Arrayref of module names loaded sequentially by the default
C<do_preload>.

=item do_preload($svc)

Performs the initial-load step in the service process. Defaults to
C<require>ing each module returned by C<modules()>. A consumer may
override to implement custom initialization (e.g. forcing a side-
effecting bootstrap).

=item pre_fork($svc, $payload)

Runs in the preload service process before the spawn fork.

=item post_fork($svc, $payload)

Runs in the first child immediately after the spawn fork. Keep
cheap; the first child exits almost immediately.

=item pre_launch($svc, $payload)

Runs in the grandchild (test process) immediately before C<longjump>
hands control to the test file.

=back

=head1 METHODS

=over 4

=item $name = Consumer->name

B<Required.> Consumers must provide this. Class method returning the
string identifier used as the preload service / resource name and
exposed via C<preload_name> in service_started fields.

=item $arrayref = $self->modules

Returns the modules loaded sequentially by the default C<do_preload>.
Default is an empty arrayref; override in the consumer.

=item $self->do_preload($svc)

Runs in the long-lived preload service process to perform the initial
load. Default C<require>s each entry from C<modules()> and croaks with
a diagnostic naming the preload on failure. Override to bootstrap
state that simple C<require> cannot express.

=item $self->pre_fork($svc, $payload)

=item $self->post_fork($svc, $payload)

=item $self->pre_launch($svc, $payload)

Default-no-op spawn-pipeline hooks; override in the consumer as
needed. C<pre_fork> runs in the preload service process before the
spawn fork; C<post_fork> runs in the soon-to-exit intermediate child
(keep cheap); C<pre_launch> runs in the test grandchild immediately
before control transfers to the test file. C<$svc> is the live
PreloadService; C<$payload> is the spawn request payload
(C<test_file_abs>, C<run_id>, C<job_id>, C<env>, ...).

=back

=cut

package Test2::Harness2::Preload::Manager;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Test2::Harness2::Util qw/mod2file/;
use Test2::Harness2::Preload;
use Test2::Harness2::Preload::Stage;
use Test2::Harness2::Preload::StageService;

use Test2::Harness2::Util::HashBase qw{
    <preload_dsl
    <preloads
    <workspace
    <includes
    <_stages
    <_stage_pids
    <_started
};

sub init {
    my $self = shift;

    $self->{+_STAGES}     = {};
    $self->{+_STAGE_PIDS} = {};
    $self->{+_STARTED}    = 0;
    $self->{+PRELOADS} //= [];
    $self->{+INCLUDES} //= [];
}

sub start {
    my $self = shift;

    # Load preload modules and discover their DSL objects
    for my $mod (@{$self->{+PRELOADS}}) {
        my $file = mod2file($mod);
        my $ok   = eval { require $file; 1 };
        my $err  = $@;
        die "Failed to load preload module '$mod': $err" unless $ok;

        if ($mod->can('TEST2_HARNESS_PRELOAD')) {
            $self->{+PRELOAD_DSL} //= Test2::Harness2::Preload->new();
            $self->{+PRELOAD_DSL}->merge($mod->TEST2_HARNESS_PRELOAD);
        }
    }

    # If no DSL preload found, create a simple 'default' stage that loads
    # the preload modules directly
    if (!$self->{+PRELOAD_DSL} || !@{$self->{+PRELOAD_DSL}->stage_list}) {
        $self->{+PRELOAD_DSL} //= Test2::Harness2::Preload->new();

        my @mods = @{$self->{+PRELOADS}};

        # Build a default stage directly (without DSL export functions)
        my $stage = Test2::Harness2::Preload::Stage->new(
            name          => 'default',
            load_sequence => [@mods],
            frame         => [__PACKAGE__, __FILE__, __LINE__],
        );

        $self->{+PRELOAD_DSL}->set_default_stage('default');
        $self->{+PRELOAD_DSL}->add_stage($stage, [__PACKAGE__, __FILE__, __LINE__]);
    }

    # Create a StageService for each stage
    my $preload = $self->{+PRELOAD_DSL};
    for my $root_stage (@{$preload->stage_list}) {
        my @all = ($root_stage, @{$root_stage->all_children});
        for my $stage_def (@all) {
            my $name = $stage_def->name;
            my $svc  = Test2::Harness2::Preload::StageService->new(
                stage_def => $stage_def,
            );

            my $ok  = eval { $svc->load_modules(); 1 };
            my $err = $@;
            warn "Failed to load modules for stage '$name': $err" unless $ok;

            $self->{+_STAGES}->{$name} = $svc;
        }
    }

    $self->{+_STARTED} = 1;

    return 1;
}

sub stop {
    my $self = shift;
    # Phase 3: no-op since we don't fork stage processes
    $self->{+_STARTED} = 0;
    return 1;
}

sub is_ready {
    my $self = shift;
    return $self->{+_STARTED} ? 1 : 0;
}

sub stage_for_test {
    my $self = shift;
    my ($requested_stage) = @_;

    my $stages = $self->{+_STAGES};

    # If a specific stage was requested and exists, return it
    if (defined $requested_stage && $stages->{$requested_stage}) {
        return $requested_stage;
    }

    # Try the default stage from the preload DSL
    if (my $preload = $self->{+PRELOAD_DSL}) {
        my $default = $preload->default_stage;
        if (defined $default) {
            # default_stage may return a name (string) or a Stage object
            my $name = ref($default) ? $default->name : $default;
            return $name if $stages->{$name};
        }
    }

    # Return the first available stage
    my @names = keys %$stages;
    return $names[0] if @names;

    return undef;
}

sub launch_test {
    my $self   = shift;
    my %params = @_;

    my $stage_name = $self->stage_for_test($params{stage});
    return undef unless $stage_name;

    my $svc = $self->{+_STAGES}->{$stage_name}
        or return undef;

    return $svc->launch_test(%params);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preload::Manager - Root preload coordinator

=head1 DESCRIPTION

The Preload::Manager is the root preload coordinator. It takes a Preload DSL
object (stage tree definitions) and/or a list of preload module names, creates
StageService instances for each stage, loads their modules, and dispatches test
launch requests to the appropriate stage.

=head1 SYNOPSIS

    use Test2::Harness2::Preload::Manager;

    my $manager = Test2::Harness2::Preload::Manager->new(
        preloads  => ['Scalar::Util', 'List::Util'],
        workspace => $workspace,
        includes  => ['lib'],
    );

    $manager->start();

    my $result = $manager->launch_test(
        test_file => 't/foo.t',
        log_dir   => '/tmp/logs',
        uuid      => 'abc-123',
        includes  => ['lib'],
    );

    $manager->stop();

=head1 ATTRIBUTES

=over 4

=item preload

Optional L<Test2::Harness2::Preload> DSL object with stage definitions.

=item preloads

Optional arrayref of module names to load as preloads.

=item workspace

L<Test2::Harness2::Workspace> object.

=item includes

Optional arrayref of C<-I> include paths.

=back

=head1 METHODS

=over 4

=item $manager->start()

Load all preload modules, discover stage definitions, create StageService
instances, and load their modules. Marks the manager as ready.

=item $manager->stop()

Stop the manager. Currently a no-op in Phase 3.

=item $manager->is_ready()

Returns true if the manager has been started.

=item $name = $manager->stage_for_test($requested_stage)

Returns the stage name to use for a test. Checks the requested stage first,
then the default stage, then the first available stage.

=item $result = $manager->launch_test(%params)

Launch a test through the appropriate stage. Returns a result hashref or undef
if no stage is available. Params: test_file, log_dir, uuid, includes, env,
switches, stage.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

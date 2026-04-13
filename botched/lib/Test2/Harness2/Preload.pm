package Test2::Harness2::Preload;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak confess/;

use Test2::Harness2::Preload::Stage();

sub import {
    my $class  = shift;
    my $caller = caller;

    my %exports;

    my $instance = $class->new;

    $exports{TEST2_HARNESS_PRELOAD} = sub { $instance };

    $exports{stage} = sub {
        my ($name, $code) = @_;
        my @caller = caller();
        $instance->build_stage(
            name   => $name,
            code   => $code,
            caller => \@caller,
        );
    };

    $exports{eager} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->set_eager(1);
    };

    $exports{default} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        my $name  = $stage->name;
        $instance->set_default_stage($name);
    };

    for my $name (qw/pre_fork post_fork pre_launch/) {
        my $meth = "add_${name}_callback";
        $exports{$name} = sub {
            croak "No current stage" unless @{$instance->stack};
            my $stage = $instance->stack->[-1];
            $stage->$meth(@_);
        };
    }

    $exports{watch} = sub {
        if (@{$instance->stack}) {
            my $stage = $instance->stack->[-1];
            return $stage->watch(@_);
        }

        if ($INC{'Test2/Harness2/Reloader.pm'}) {
            if (my $active = Test2::Harness2::Reloader->ACTIVE) {
                return $active->watch(@_);
            }
        }

        if (my $stage = $Test2::Harness2::Runner::Preloading::Stage::ACTIVE) {
            return $stage->watch(@_);
        }

        croak "$$ $0 - No current stage, and no active reloader";
    };

    $exports{preload} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->add_to_load_sequence(@_);
    };

    $exports{reload_inplace_check} = sub {
        croak "No current stage" unless @{$instance->stack};
        my $stage = $instance->stack->[-1];
        $stage->set_reload_inplace_check(@_);
    };

    for my $name (keys %exports) {
        no strict 'refs';
        *{"$caller\::$name"} = $exports{$name};
    }
}

use Test2::Harness2::Util::HashBase qw{
    <stage_list
    <stage_lookup
    <stack
    +default_stage
};

sub init {
    my $self = shift;

    $self->{+STAGE_LIST}   //= [];
    $self->{+STAGE_LOOKUP} //= {};
    $self->{+STACK}        //= [];
}

sub build_stage {
    my $self   = shift;
    my %params = @_;

    my $caller = $params{caller} //= [caller()];

    die "A coderef is required at $caller->[1] line $caller->[2].\n"
        unless $params{code};

    my $stage = Test2::Harness2::Preload::Stage->new(
        stage_lookup => $self->{+STAGE_LOOKUP},
        %params,
    );

    my $stack = $self->{+STACK} //= [];
    push @$stack => $stage;

    my $ok  = eval { $params{code}->($stage); 1 };
    my $err = $@;

    die "Mangled stack" unless @$stack && $stack->[-1] eq $stage;

    pop @$stack;

    die $err unless $ok;

    if (@$stack) {
        $stack->[-1]->add_child($stage);
    }
    else {
        $self->add_stage($stage, $caller);
    }

    return $stage;
}

sub add_stage {
    my $self = shift;
    my ($stage, $caller) = @_;

    $caller //= [caller()];

    my @all = ($stage, @{$stage->all_children});

    for my $item (@all) {
        my $name = $item->name;

        if (my $existing = $self->{+STAGE_LOOKUP}->{$name}) {
            my $ncaller = $item->frame;
            my $ecaller = $existing->frame;
            die <<"            EOT";
A stage named '$name' was already defined.
  First at  $ecaller->[1] line $ecaller->[2].
  Second at $ncaller->[1] line $ncaller->[2].
  Mixed at  $caller->[1] line $caller->[2].
            EOT
        }

        $self->{+STAGE_LOOKUP}->{$name} = $item;
    }

    push @{$self->{+STAGE_LIST}} => $stage;
}

sub merge {
    my $self = shift;
    my ($merge) = @_;

    my $caller = [caller()];

    for my $stage (@{$merge->{+STAGE_LIST}}) {
        $self->add_stage($stage, $caller);
    }

    $self->{+DEFAULT_STAGE} //= $merge->default_stage;
}

sub add_file_stage { confess "deprecated, use a plugin to assign stages to tests" }
sub file_stage     { confess "deprecated, use a plugin to assign stages to tests" }

sub default_stage {
    my $self = shift;
    return $self->{+DEFAULT_STAGE} if $self->{+DEFAULT_STAGE};
    return $self->{+STAGE_LIST}->[0];
}

sub set_default_stage {
    my $self = shift;
    my ($name) = @_;

    croak "Default stage already set to $self->{+DEFAULT_STAGE}" if $self->{+DEFAULT_STAGE};
    $self->{+DEFAULT_STAGE} = $name;
}

sub eager_stages {
    my $self = shift;

    my %eager;

    for my $root (@{$self->{+STAGE_LIST}}) {
        for my $stage ($root, @{$root->all_children}) {
            next unless $stage->eager;
            $eager{$stage->name} = [map { $_->name } @{$stage->all_children}];
        }
    }

    return \%eager;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preload - DSL for building complex stage-based preload tools.

=head1 DESCRIPTION

L<Test2::Harness2> allows you to preload libraries for a performance boost. This
module provides tools that let you go beyond that and build a more complex
preload. In addition you can build multiple preload I<stages>, each stage will
be its own process and tests can run from a specific stage. This allows for
multiple different preload states from which to run tests.

=head1 SYNOPSIS

=head2 USING YOUR PRELOAD

The C<-P> or C<--preload> options work for custom preload modules just as they
do regular modules. Yath will know the difference and act accordingly.

    yath test -PMy::Preload

=head2 WRITING YOUR PRELOAD

    package My::Preload;
    use strict;
    use warnings;

    use Test2::Harness2::Preload;

    stage Moose => sub {
        preload 'Moose', 'Moose::Role';
        preload 'Scalar::Util', 'List::Util';

        preload sub {
            # Do something custom
        };

        preload 'Try::Tiny';

        eager();
        default();

        pre_fork sub { ... };
        post_fork sub { ... };
        pre_launch sub { ... };

        stage Types => sub {
            preload 'MooseX::Types';
        };
    };

    stage Moo => sub {
        preload 'Moo';
    };

=head1 EXPORTS

=over 4

=item $meta = TEST2_HARNESS_PRELOAD()

=item $meta = $class->TEST2_HARNESS_PRELOAD()

Returns the meta object (an instance of this class) for the calling package.

=item stage NAME => sub { ... }

Creates a new stage with the given C<NAME> and executes the coderef with the
new stage as the active stage.

=item preload $module_name

=item preload @module_names

=item preload sub { ... }

Adds modules or coderefs to the active stage's load sequence.

=item eager()

Marks the active stage as eager.

=item default()

Marks the active stage as the default stage. May only be called once.

=item pre_fork sub { ... }

Adds a callback to run just before the stage process forks to run a test.

=item post_fork sub { ... }

Adds a callback to run just after the stage process forks for a test.

=item pre_launch sub { ... }

Adds a callback to run just before the test starts executing.

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

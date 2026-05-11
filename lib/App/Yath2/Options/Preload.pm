package App::Yath2::Options::Preload;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Getopt::Yath;

use Importer Importer => 'import';
our @EXPORT_OK = qw/classify_preload_modules/;

option_group {group => 'preload', category => "Preload Options"} => sub {
    option modules => (
        type           => 'List',
        short          => 'P',
        alt            => ['preload'],
        field          => 'modules',

        description => 'Pre-load one or more Perl modules in a long-lived preload service; tests then run as forks of that service with %INC already populated. Repeat -P (or comma-separate) for multiple modules. The "default" preload (a single Resource::Preload spawning one PreloadService) carries every bare module supplied on the command line.',

        long_examples  => [' Moose', ' My::Heavy::Module', ' Foo,Bar,Baz'],
        short_examples => [' Moose', ' My::Heavy::Module', ' Foo,Bar,Baz'],

        normalize => sub {
            my ($v) = @_;
            return ref($v) ? @$v : split(/,/, $v);
        },
    );
};

# Classify the -P modules list into preload groups.
#
# Returns a list of hashrefs, each shaped:
#   { name => 'default', modules => \@bare_modules, is_role_consumer => 0 }
#   { name => $role_name, modules => [$role_module], is_role_consumer => 1 }
#
# A module consuming Test2::Harness2::Role::Preload becomes its own
# named preload (one per role consumer, named after that class's
# name() method). Bare modules collect into one 'default' bucket.
#
# The classifier require()s each module client-side. Failure to load
# a -P module is fatal here -- the user supplied it explicitly and a
# typo / missing dist should surface before the daemon spawns.
sub classify_preload_modules {
    my ($modules) = @_;
    $modules //= [];
    return () unless ref($modules) eq 'ARRAY' && @$modules;

    require Test2::Harness2::Util;
    require Role::Tiny;

    my @bare;
    my @role_groups;
    my %seen_role_name;

    for my $mod (@$modules) {
        croak "preload module name is empty or undef"
            unless defined $mod && length $mod;

        my $file = Test2::Harness2::Util::mod2file($mod);
        my $ok = eval { require $file; 1 };
        unless ($ok) {
            my $err = $@;
            chomp $err;
            croak "Failed to load -P module '$mod': $err";
        }

        if (Role::Tiny::does_role($mod, 'Test2::Harness2::Role::Preload')) {
            my $name = eval { $mod->name };
            croak "preload class '$mod' consumes Test2::Harness2::Role::Preload but ->name died: $@"
                unless defined $name;
            croak "preload class '$mod' returned an empty/undef name"
                unless length $name;
            croak "preload class '$mod' returned name '$name' which collides with another -P role consumer"
                if $seen_role_name{$name}++;

            push @role_groups => {
                name             => $name,
                modules          => [$mod],
                is_role_consumer => 1,
            };
            next;
        }

        push @bare => $mod;
    }

    my @out;
    push @out => {
        name             => 'default',
        modules          => \@bare,
        is_role_consumer => 0,
    } if @bare;
    push @out => @role_groups;

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Preload - C<-P> / C<--preload> CLI options.

=head1 DESCRIPTION

Defines the C<--preload> / C<-P> option group. Modules listed via
this option are loaded by a long-lived preload service so that tests
launched by the harness run as forks of the preload process and
inherit the pre-populated C<%INC>.

The C<test> command consumes this group's C<modules> list and, when
non-empty, injects a single L<Test2::Harness2::Resource::Preload>
named C<default> into the harness's resources. Tests that do not
opt out (via C<HARNESS-PRELOAD: E<lt>noE<gt>>) route through that
preload service automatically.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

See L<https://dev.perl.org/licenses/>

=cut

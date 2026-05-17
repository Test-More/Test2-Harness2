package App::Yath2::Preload;
use strict;
use warnings;

our $VERSION = '2.000013';

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Preload - Build L<Test2::Harness2::Resource::Preload> args from CLI settings.

=head1 DESCRIPTION

Central preload-binding helpers used by C<yath test>, C<yath start>,
and C<yath run>. Reads the C<--preload> / C<--reloader> option groups
from a parsed L<Getopt::Yath> settings object and produces the
constructor argument hashes that each command then materialises (as
objects, in test/start, or as resource specs, in run).

=head1 EXPORTS

C<classify_preload_modules>, C<resolve_reloader_class>,
C<preload_resource_args>.

=cut

use Carp qw/croak/;

use Importer Importer => 'import';
our @EXPORT_OK = qw{
    classify_preload_modules
    resolve_reloader_class
    preload_resource_args
};

=head2 preload_resource_args(settings => $s, scope => 'run'?)

Returns a list of constructor-arg hashrefs (one per preload group).
Each hash is shaped for L<Test2::Harness2::Resource::Preload>:
C<name>, C<modules>, C<is_role_consumer>, plus C<scope> when one was
requested and C<reloader_class> when the reloader option resolved to
a backend. Returns the empty list when no preload modules were
configured.

=cut

sub preload_resource_args {
    my (%args) = @_;
    my $settings = $args{settings} or croak "settings required";
    my $scope    = $args{scope};

    my $modules = _modules_from_settings($settings);
    return () unless $modules && @$modules;

    my $reloader_class = resolve_reloader_class(_reloader_backend_from_settings($settings));

    my @out;
    for my $group (classify_preload_modules($modules)) {
        push @out => {
            %$group,
            (defined $scope          ? (scope          => $scope)          : ()),
            (defined $reloader_class ? (reloader_class => $reloader_class) : ()),
        };
    }
    return @out;
}

=head2 _modules_from_settings($settings)

Returns the C<modules> arrayref from C<$settings-E<gt>preload>, or
C<undef> when the option group is absent. The eval-traps are needed
because L<Getopt::Yath::Settings> dispatches group accessors
dynamically and does not respond to C<-E<gt>can('preload')>.

=cut

sub _modules_from_settings {
    my ($settings) = @_;
    my $preload = eval { $settings->preload };
    return undef unless $preload && eval { $preload->check_option('modules') };
    return $preload->modules;
}

=head2 _reloader_backend_from_settings($settings)

Returns the normalized reloader backend name from
C<$settings-E<gt>reloader-E<gt>backend>, or C<undef>.

=cut

sub _reloader_backend_from_settings {
    my ($settings) = @_;
    return eval { $settings->reloader->backend };
}

=head2 resolve_reloader_class($backend)

Maps a normalized backend name (C<mstat>, C<inotify>, C<none>) to a
concrete reloader class, or C<undef> when no reloader should be
installed. Croaks on an unknown backend.

=cut

sub resolve_reloader_class {
    my ($backend) = @_;
    return undef unless defined $backend && length $backend;
    $backend = lc $backend;
    return undef                                  if $backend eq 'none';
    return 'Test2::Harness2::Reloader::HiResStat' if $backend eq 'mstat';
    return 'Test2::Harness2::Reloader::INotify'   if $backend eq 'inotify';
    croak "Unknown --reloader backend '$backend'";
}

=head2 classify_preload_modules(\@modules)

Classifies a list of C<-P> module names into preload groups. Each
returned hashref is shaped:

    { name => 'default',  modules => \@bare_modules,  is_role_consumer => 0 }
    { name => $role_name, modules => [$role_module],  is_role_consumer => 1 }

Modules consuming L<Test2::Harness2::Role::Preload> become their own
named preload (one per role consumer, keyed on the class's C<name()>
method). Bare modules collect into a single C<default> bucket. Each
module is C<require>'d client-side and a load failure croaks -- the
user supplied this option, so a typo / missing dist should surface
before the daemon spawns.

=cut

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
        _require_preload_module($mod);

        if (my $group = _role_group($mod, \%seen_role_name)) {
            push @role_groups => $group;
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

=head2 _require_preload_module($mod)

C<require>s C<$mod>. Croaks on empty/undef name or load failure.

=cut

sub _require_preload_module {
    my ($mod) = @_;
    croak "preload module name is empty or undef"
        unless defined $mod && length $mod;

    my $file = Test2::Harness2::Util::mod2file($mod);
    my $ok   = eval { require $file; 1 };
    return if $ok;

    my $err = $@;
    chomp $err;
    croak "Failed to load -P module '$mod': $err";
}

=head2 _role_group($mod, \%seen_names)

When C<$mod> consumes L<Test2::Harness2::Role::Preload>, returns a
preload-group hashref keyed on C<< $mod->name >>. Croaks on a missing
/ empty name or a name collision with another role consumer in the
same call. Returns C<undef> for non-role-consumer modules.

=cut

sub _role_group {
    my ($mod, $seen) = @_;
    return undef unless Role::Tiny::does_role($mod, 'Test2::Harness2::Role::Preload');

    my $name = eval { $mod->name };
    croak "preload class '$mod' consumes Test2::Harness2::Role::Preload but ->name died: $@"
        unless defined $name;
    croak "preload class '$mod' returned an empty/undef name"
        unless length $name;
    croak "preload class '$mod' returned name '$name' which collides with another -P role consumer"
        if $seen->{$name}++;

    return {
        name             => $name,
        modules          => [$mod],
        is_role_consumer => 1,
    };
}

1;

__END__

=pod

=head1 SEE ALSO

L<Test2::Harness2::Resource::Preload>, L<Test2::Harness2::Role::Preload>,
L<Test2::Harness2::Reloader::HiResStat>, L<Test2::Harness2::Reloader::INotify>,
L<App::Yath2::Options::Preload>, L<App::Yath2::Options::Reloader>.

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

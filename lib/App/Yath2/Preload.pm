package App::Yath2::Preload;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Importer Importer => 'import';
our @EXPORT_OK = qw{
    classify_preload_modules
    resolve_reloader_class
    preload_resource_args
};

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

sub _modules_from_settings {
    my ($settings) = @_;
    my $preload = eval { $settings->preload };
    return undef unless $preload && eval { $preload->check_option('modules') };
    return $preload->modules;
}

sub _reloader_backend_from_settings {
    my ($settings) = @_;
    return eval { $settings->reloader->backend };
}

sub resolve_reloader_class {
    my ($backend) = @_;
    return undef unless defined $backend && length $backend;
    $backend = lc $backend;
    return undef                                  if $backend eq 'none';
    return 'Test2::Harness2::Reloader::HiResStat' if $backend eq 'mstat';
    return 'Test2::Harness2::Reloader::INotify'   if $backend eq 'inotify';
    croak "Unknown --reloader backend '$backend'";
}

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

use Test2::V0;

# The canonical Resource surface is the Role::Tiny role
# Test2::Harness2::Role::Resource. Concrete resources consume it via
# Object::HashBase's '&Test2::Harness2::Role::Resource' syntax. The
# preferred_preload opt-in seam lives on the role so every consumer
# inherits the undef default; subclasses (and per-instance overrides
# in Resource::Preload) opt in to PreloadService-based spawn.

use Test2::Harness2::Role::Resource;

# Minimal class that consumes the role -- can't bless directly into a
# Role::Tiny role because it isn't a real package class. The role's
# methods are installed into the consumer at composition time.
{
    package My::Res::Base;
    use Object::HashBase qw{
        &Test2::Harness2::Role::Resource
    };
    sub available { 1 }
    sub status    { {} }
}

my $base = My::Res::Base->new;
is($base->preferred_preload, undef, 'base consumer returns undef by default');

# Class-level override (fixed target across all instances).
{
    package My::Res::Foo;
    use parent -norequire, 'My::Res::Base';
    sub preferred_preload { 'myapp' }
}
my $foo = My::Res::Foo->new;
is($foo->preferred_preload, 'myapp', 'class-level override returns its name');

# Subclass without override falls back to base default.
{
    package My::Res::Bar;
    use parent -norequire, 'My::Res::Base';
}
my $bar = My::Res::Bar->new;
is($bar->preferred_preload, undef, 'subclass without override returns undef');

# Instance-level override via slot. Subclasses that store per-instance
# preload target (Resource::Preload, primarily) can override to read
# from a HashBase slot.
{
    package My::Res::Configurable;
    use parent -norequire, 'My::Res::Base';
    sub preferred_preload { $_[0]->{preferred_preload} }
}
my $a = bless { preferred_preload => 'baselibs'  }, 'My::Res::Configurable';
my $b = bless { preferred_preload => 'otherbase' }, 'My::Res::Configurable';
is($a->preferred_preload, 'baselibs',  'instance A configured target');
is($b->preferred_preload, 'otherbase', 'instance B configured target');

done_testing;

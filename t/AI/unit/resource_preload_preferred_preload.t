use Test2::V0;
use Test2::Harness2::Resource::Preload;

# Direct: instances built with preferred_preload set surface it via
# the accessor.
my $p = Test2::Harness2::Resource::Preload->new(
    name              => 'app',
    modules           => [],
    preferred_preload => 'base',
);
is($p->preferred_preload, 'base', 'instance returns configured preferred_preload');

# Instance without preferred_preload returns undef (the base default
# from Role::Resource).
my $standalone = Test2::Harness2::Resource::Preload->new(
    name    => 'solo',
    modules => [],
);
is($standalone->preferred_preload, undef, 'unset instance falls through to undef');

# parse_options: from=base sets preferred_preload, name carried.
my %opts = Test2::Harness2::Resource::Preload->parse_options('from=base', 'name=app');
is($opts{preferred_preload}, 'base', 'parse_options from=base => preferred_preload');
is($opts{name},              'app',  'parse_options name carried');

# parse_options: no from= means no preferred_preload key.
my %only_name = Test2::Harness2::Resource::Preload->parse_options('name=lone');
ok(!exists $only_name{preferred_preload}, 'parse_options without from= leaves preferred_preload unset');
is($only_name{name}, 'lone', 'parse_options name-only carried');

done_testing;

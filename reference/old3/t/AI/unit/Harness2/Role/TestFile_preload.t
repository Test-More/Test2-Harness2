use Test2::V0;

# A consumer that does NOT override preload_preferences should get the
# role's default of ['<default>'], so Test2::Harness2-only callers
# (no Yath2 producer layer) can still ask the question uniformly.

package T2H2_TestFile_NoPreload {
    use Object::HashBase qw{<absolute};
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::TestFile';
    sub relative { $_[0]->absolute }
    sub TO_JSON { return { absolute => $_[0]->absolute } }
}

package T2H2_TestFile_WithPreload {
    use Object::HashBase qw{<absolute};
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::TestFile';
    sub relative { $_[0]->absolute }
    sub TO_JSON { return { absolute => $_[0]->absolute } }
    sub preload_preferences { ['Foo', '<default>'] }
}

package main;

subtest 'role default = [<default>]' => sub {
    my $tf = T2H2_TestFile_NoPreload->new(absolute => '/tmp/anything.t');
    is($tf->preload_preferences, ['<default>'], 'default preference list');
};

subtest 'consumer override wins' => sub {
    my $tf = T2H2_TestFile_WithPreload->new(absolute => '/tmp/foo.t');
    is($tf->preload_preferences, ['Foo', '<default>'], 'consumer override returned');
};

done_testing;

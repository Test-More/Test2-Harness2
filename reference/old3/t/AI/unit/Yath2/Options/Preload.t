use Test2::V0;

# -P / --preload Module: a List option living under the new
# preload option group. Multiple flags accumulate; comma-separated
# values are split into individual modules.

package TestPreload {
    use Getopt::Yath;
    include_options('App::Yath2::Options::Preload');
}

sub parse {
    my @argv = @_;
    local %ENV = %ENV;
    my $state = TestPreload::parse_options([@argv]);
    return $state->{settings}->preload;
}

subtest 'absent: modules is empty' => sub {
    my $p = parse();
    is($p->modules // [], [], '--preload not provided => empty list');
};

subtest 'single -P sets one module' => sub {
    my $p = parse('-P', 'Foo::Bar');
    is($p->modules, ['Foo::Bar'], 'single module');
};

subtest 'multiple -P accumulates' => sub {
    my $p = parse('-P', 'Foo', '-P', 'Bar');
    is($p->modules, ['Foo', 'Bar'], 'two modules');
};

subtest 'comma-separated splits' => sub {
    my $p = parse('-P', 'Foo,Bar,Baz');
    is($p->modules, ['Foo', 'Bar', 'Baz'], 'comma splits');
};

subtest 'long form --preload' => sub {
    my $p = parse('--preload', 'Quux');
    is($p->modules, ['Quux'], 'long form works');
};

done_testing;

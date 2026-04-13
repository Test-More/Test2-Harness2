use strict;
use warnings;
use Test2::V0;

use lib 't';

use Test2::Harness2::Preload;

subtest 'basic construction' => sub {
    my $preload = Test2::Harness2::Preload->new;
    ok($preload, "created Preload object");
    is($preload->stage_list,   [], "stage_list defaults to empty arrayref");
    is($preload->stage_lookup, {}, "stage_lookup defaults to empty hashref");
    is($preload->stack,        [], "stack defaults to empty arrayref");
    ok(
        !defined $preload->{Test2::Harness2::Preload::DEFAULT_STAGE()},
        "default_stage internal slot starts undef"
    );
};

subtest 'build_stage basic' => sub {
    my $preload = Test2::Harness2::Preload->new;

    my $stage = $preload->build_stage(
        name => 'MyStage',
        code => sub { },
    );

    ok($stage, "build_stage returns a stage");
    isa_ok($stage, ['Test2::Harness2::Preload::Stage'], "stage is a Stage object");
    is($stage->name, 'MyStage', "stage has correct name");

    is(scalar @{$preload->stage_list}, 1, "one root stage in stage_list");
    ok($preload->stage_lookup->{'MyStage'}, "stage registered in stage_lookup");
};

subtest 'build_stage requires coderef' => sub {
    my $preload = Test2::Harness2::Preload->new;

    like(
        dies { $preload->build_stage(name => 'Foo') },
        qr/coderef is required/,
        "dies when code is missing"
    );
};

subtest 'nested stages via DSL-like build_stage' => sub {
    my $preload = Test2::Harness2::Preload->new;

    my $root = $preload->build_stage(
        name => 'Root',
        code => sub {
            $preload->build_stage(
                name => 'Child',
                code => sub { },
            );
        },
    );

    is(scalar @{$preload->stage_list},  1,       "only one root stage");
    is($preload->stage_list->[0]->name, 'Root',  "root stage is Root");
    is(scalar @{$root->children},       1,       "root has one child");
    is($root->children->[0]->name,      'Child', "child stage is Child");

    ok($preload->stage_lookup->{'Root'},  "Root in stage_lookup");
    ok($preload->stage_lookup->{'Child'}, "Child in stage_lookup");
    is(scalar keys %{$preload->stage_lookup}, 2, "exactly two stages in lookup");
};

subtest 'duplicate stage name dies' => sub {
    my $preload = Test2::Harness2::Preload->new;

    $preload->build_stage(name => 'Dup', code => sub { });

    like(
        dies {
            $preload->build_stage(name => 'Dup', code => sub { })
        },
        qr/already defined/,
        "dies on duplicate stage name"
    );
};

subtest 'default_stage' => sub {
    my $preload = Test2::Harness2::Preload->new;

    # Without any stages, default_stage returns undef (first element of empty list)
    ok(!defined $preload->default_stage, "default_stage is undef with no stages");

    # With stages but no explicit default, returns first stage
    $preload->build_stage(name => 'First',  code => sub { });
    $preload->build_stage(name => 'Second', code => sub { });

    is(
        $preload->default_stage->name, 'First',
        "default_stage returns first stage when no explicit default"
    );

    my $preload2 = Test2::Harness2::Preload->new;
    $preload2->build_stage(name => 'Alpha', code => sub { });
    $preload2->build_stage(name => 'Beta',  code => sub { });
    $preload2->set_default_stage('Beta');

    is(
        $preload2->default_stage, 'Beta',
        "set_default_stage overrides first-stage default"
    );
};

subtest 'set_default_stage dies on second call' => sub {
    my $preload = Test2::Harness2::Preload->new;
    $preload->build_stage(name => 'A', code => sub { });
    $preload->build_stage(name => 'B', code => sub { });

    $preload->set_default_stage('A');

    like(
        dies { $preload->set_default_stage('B') },
        qr/Default stage already set/,
        "dies when default stage set twice"
    );
};

subtest 'eager_stages' => sub {
    my $preload = Test2::Harness2::Preload->new;

    $preload->build_stage(
        name => 'Eager',
        code => sub {
            $preload->stage_lookup->{'Eager'} // do {
                # eager will be set after build, handle via stack
            };
            my $self_stage = $preload->stack->[-1];
            $self_stage->set_eager(1);

            $preload->build_stage(name => 'EagerChild1', code => sub { });
            $preload->build_stage(name => 'EagerChild2', code => sub { });
        },
    );

    $preload->build_stage(
        name => 'NotEager',
        code => sub {
            $preload->build_stage(name => 'NotEagerChild', code => sub { });
        },
    );

    my $eager = $preload->eager_stages;
    ok($eager->{'Eager'},     "Eager stage is in eager_stages result");
    ok(!$eager->{'NotEager'}, "NotEager stage is not in eager_stages result");

    my @child_names = sort @{$eager->{'Eager'}};
    is(
        \@child_names, [qw/EagerChild1 EagerChild2/],
        "eager_stages lists children of eager stage"
    );
};

subtest 'merge' => sub {
    my $preload1 = Test2::Harness2::Preload->new;
    $preload1->build_stage(name => 'StageA', code => sub { });
    $preload1->set_default_stage('StageA');

    my $preload2 = Test2::Harness2::Preload->new;
    $preload2->build_stage(name => 'StageB', code => sub { });

    $preload1->merge($preload2);

    ok($preload1->stage_lookup->{'StageA'}, "StageA still in lookup after merge");
    ok($preload1->stage_lookup->{'StageB'}, "StageB merged into lookup");
    is(scalar @{$preload1->stage_list}, 2, "two root stages after merge");

    # Default stage preserved from first preload
    is($preload1->default_stage, 'StageA', "default stage preserved from first preload");
};

subtest 'merge inherits default when first has none' => sub {
    my $preload1 = Test2::Harness2::Preload->new;
    $preload1->build_stage(name => 'StageX', code => sub { });

    my $preload2 = Test2::Harness2::Preload->new;
    $preload2->build_stage(name => 'StageY', code => sub { });
    $preload2->set_default_stage('StageY');

    $preload1->merge($preload2);

    is(
        $preload1->{Test2::Harness2::Preload::DEFAULT_STAGE()}, 'StageY',
        "default stage inherited from merged preload when first had none"
    );
};

subtest 'merge dies on duplicate stage names' => sub {
    my $preload1 = Test2::Harness2::Preload->new;
    $preload1->build_stage(name => 'Shared', code => sub { });

    my $preload2 = Test2::Harness2::Preload->new;
    $preload2->build_stage(name => 'Shared', code => sub { });

    like(
        dies { $preload1->merge($preload2) },
        qr/already defined/,
        "merge dies when stage names collide"
    );
};

subtest 'fixture module: TEST2_HARNESS_PRELOAD' => sub {
    require selftest::preload_def;

    can_ok(
        't::selftest::preload_def', ['TEST2_HARNESS_PRELOAD'],
        "fixture exports TEST2_HARNESS_PRELOAD"
    );

    my $meta = t::selftest::preload_def->TEST2_HARNESS_PRELOAD;
    ok($meta, "TEST2_HARNESS_PRELOAD returns an object");
    isa_ok($meta, ['Test2::Harness2::Preload'], "meta object is a Preload instance");
};

subtest 'fixture module: stage tree structure' => sub {
    my $meta = t::selftest::preload_def->TEST2_HARNESS_PRELOAD;

    is(scalar @{$meta->stage_list}, 2, "two root stages");

    my @root_names = sort map { $_->name } @{$meta->stage_list};
    is(\@root_names, [qw/default isolation/], "root stages are 'default' and 'isolation'");

    my $default_stage = $meta->stage_lookup->{'default'};
    ok($default_stage, "default stage in lookup");
    is(scalar @{$default_stage->children},  1,       "default stage has one child");
    is($default_stage->children->[0]->name, 'child', "child stage is 'child'");

    ok($meta->stage_lookup->{'child'},     "child stage in lookup");
    ok($meta->stage_lookup->{'isolation'}, "isolation stage in lookup");
    is(scalar keys %{$meta->stage_lookup}, 3, "exactly 3 stages in lookup");
};

subtest 'fixture module: default_stage set correctly' => sub {
    my $meta = t::selftest::preload_def->TEST2_HARNESS_PRELOAD;

    is(
        $meta->default_stage, 'default',
        "default_stage is 'default' as set by default() DSL call"
    );
};

subtest 'fixture module: load_sequence populated' => sub {
    my $meta = t::selftest::preload_def->TEST2_HARNESS_PRELOAD;

    my $default_stage = $meta->stage_lookup->{'default'};
    my $seq           = $default_stage->load_sequence;
    is(
        $seq, [qw/Scalar::Util List::Util/],
        "default stage load_sequence has Scalar::Util and List::Util"
    );

    my $child_stage = $meta->stage_lookup->{'child'};
    is(
        $child_stage->load_sequence, ['File::Spec'],
        "child stage load_sequence has File::Spec"
    );

    my $isolation_stage = $meta->stage_lookup->{'isolation'};
    is(
        $isolation_stage->load_sequence, ['Carp'],
        "isolation stage load_sequence has Carp"
    );
};

subtest 'deprecated methods die' => sub {
    my $preload = Test2::Harness2::Preload->new;

    like(
        dies { $preload->add_file_stage('foo') },
        qr/deprecated/,
        "add_file_stage dies with deprecated message"
    );

    like(
        dies { $preload->file_stage('foo') },
        qr/deprecated/,
        "file_stage dies with deprecated message"
    );
};

done_testing;

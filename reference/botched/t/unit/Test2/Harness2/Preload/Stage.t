use strict;
use warnings;
use Test2::V0;

use File::Temp qw/tempfile/;

use Test2::Harness2::Preload::Stage;

subtest 'basic construction' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'MyStage');
    ok($stage, "created Stage object");
    is($stage->name,                 'MyStage', "name attribute set");
    is($stage->children,             [],        "children default to empty arrayref");
    is($stage->load_sequence,        [],        "load_sequence default to empty arrayref");
    is($stage->pre_fork_callbacks,   [],        "pre_fork_callbacks default to empty arrayref");
    is($stage->post_fork_callbacks,  [],        "post_fork_callbacks default to empty arrayref");
    is($stage->pre_launch_callbacks, [],        "pre_launch_callbacks default to empty arrayref");
    is($stage->watches,              {},        "watches default to empty hashref");
    is($stage->eager,                0,         "eager defaults to 0");
};

subtest 'name is required' => sub {
    ok(
        dies { Test2::Harness2::Preload::Stage->new() },
        "dies when name is missing"
    );

    like(
        dies { Test2::Harness2::Preload::Stage->new(name => '') },
        qr/required/,
        "dies with empty name"
    );
};

subtest 'reserved name base (case-insensitive)' => sub {
    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'base') },
        qr/reserved/,
        "dies for 'base'"
    );
    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'Base') },
        qr/reserved/,
        "dies for 'Base' (case-insensitive)"
    );
    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'BASE') },
        qr/reserved/,
        "dies for 'BASE' (case-insensitive)"
    );
};

subtest 'reserved name NOPRELOAD (case-insensitive)' => sub {
    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'NOPRELOAD') },
        qr/reserved/,
        "dies for 'NOPRELOAD'"
    );
    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'nopreload') },
        qr/reserved/,
        "dies for 'nopreload' (case-insensitive)"
    );
    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'NoPreload') },
        qr/reserved/,
        "dies for 'NoPreload' (case-insensitive)"
    );
};

subtest 'frame attribute' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'FrameTest');
    ok($stage->frame, "frame is set automatically");
    is(ref($stage->frame), 'ARRAY', "frame is an arrayref");

    my $explicit_frame = ['foo.pm', 42, 'main', 'foo'];
    my $stage2         = Test2::Harness2::Preload::Stage->new(
        name  => 'FrameTest2',
        frame => $explicit_frame,
    );
    is($stage2->frame, $explicit_frame, "explicit frame is preserved");
};

subtest 'eager flag' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'EagerStage', eager => 1);
    is($stage->eager, 1, "eager can be set to 1");
};

subtest 'add_child and children management' => sub {
    my $parent = Test2::Harness2::Preload::Stage->new(name => 'Parent');
    my $child1 = Test2::Harness2::Preload::Stage->new(name => 'Child1');
    my $child2 = Test2::Harness2::Preload::Stage->new(name => 'Child2');

    $parent->add_child($child1);
    $parent->add_child($child2);

    is(scalar @{$parent->children},  2,        "two children added");
    is($parent->children->[0]->name, 'Child1', "first child is Child1");
    is($parent->children->[1]->name, 'Child2', "second child is Child2");
};

subtest 'all_children recursive' => sub {
    my $root   = Test2::Harness2::Preload::Stage->new(name => 'Root');
    my $child1 = Test2::Harness2::Preload::Stage->new(name => 'Child1');
    my $child2 = Test2::Harness2::Preload::Stage->new(name => 'Child2');
    my $grand1 = Test2::Harness2::Preload::Stage->new(name => 'Grand1');
    my $grand2 = Test2::Harness2::Preload::Stage->new(name => 'Grand2');

    $root->add_child($child1);
    $root->add_child($child2);
    $child1->add_child($grand1);
    $child2->add_child($grand2);

    my $all = $root->all_children;
    is(ref($all),      'ARRAY', "all_children returns arrayref");
    is(scalar @{$all}, 4,       "all_children returns all 4 descendants");

    my @names = sort map { $_->name } @{$all};
    is(\@names, [qw/Child1 Child2 Grand1 Grand2/], "all descendants present");
};

subtest 'all_children with no children' => sub {
    my $leaf = Test2::Harness2::Preload::Stage->new(name => 'Leaf');
    my $all  = $leaf->all_children;
    is($all, [], "all_children returns empty arrayref for leaf node");
};

subtest 'add_to_load_sequence' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'LoadSeq');

    $stage->add_to_load_sequence('Some::Module', 'Another::Module');
    is(
        $stage->load_sequence, ['Some::Module', 'Another::Module'],
        "module name strings added to load_sequence"
    );

    my $cb = sub { 1 };
    $stage->add_to_load_sequence($cb);
    is(scalar @{$stage->load_sequence}, 3,   "coderef added to load_sequence");
    is($stage->load_sequence->[2],      $cb, "coderef is the same ref");

    like(
        dies { $stage->add_to_load_sequence({}) },
        qr/not a valid preload/,
        "dies for invalid item (hashref)"
    );
};

subtest 'pre_fork callbacks' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'PreFork');

    my @called;
    $stage->add_pre_fork_callback(sub { push @called, 'first' });
    $stage->add_pre_fork_callback(sub { push @called, 'second' });

    $stage->do_pre_fork();
    is(\@called, [qw/first second/], "pre_fork callbacks called in order");

    like(
        dies { $stage->add_pre_fork_callback('not a coderef') },
        qr/coderef/,
        "add_pre_fork_callback dies for non-coderef"
    );
};

subtest 'post_fork callbacks' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'PostFork');

    my @called;
    $stage->add_post_fork_callback(sub { push @called, 'first' });
    $stage->add_post_fork_callback(sub { push @called, 'second' });

    $stage->do_post_fork();
    is(\@called, [qw/first second/], "post_fork callbacks called in order");

    like(
        dies { $stage->add_post_fork_callback('not a coderef') },
        qr/coderef/,
        "add_post_fork_callback dies for non-coderef"
    );
};

subtest 'pre_launch callbacks' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'PreLaunch');

    my @called;
    $stage->add_pre_launch_callback(sub { push @called, 'first' });
    $stage->add_pre_launch_callback(sub { push @called, 'second' });

    $stage->do_pre_launch();
    is(\@called, [qw/first second/], "pre_launch callbacks called in order");

    like(
        dies { $stage->add_pre_launch_callback('not a coderef') },
        qr/coderef/,
        "add_pre_launch_callback dies for non-coderef"
    );
};

subtest 'callbacks receive arguments' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'CBArgs');

    my @got_args;
    $stage->add_pre_fork_callback(sub { @got_args = @_ });
    $stage->do_pre_fork('arg1', 'arg2');
    is(\@got_args, [qw/arg1 arg2/], "pre_fork callback receives arguments");

    @got_args = ();
    $stage->add_post_fork_callback(sub { @got_args = @_ });
    $stage->do_post_fork('x', 'y');
    is(\@got_args, [qw/x y/], "post_fork callback receives arguments");

    @got_args = ();
    $stage->add_pre_launch_callback(sub { @got_args = @_ });
    $stage->do_pre_launch('p', 'q');
    is(\@got_args, [qw/p q/], "pre_launch callback receives arguments");
};

subtest 'watches' => sub {
    my $stage = Test2::Harness2::Preload::Stage->new(name => 'Watches');

    my ($fh, $tmpfile) = tempfile(UNLINK => 1);
    close $fh;

    my $cb = sub { 'watched' };
    $stage->watch($tmpfile, $cb);

    my $watches = $stage->watches;
    my @keys    = keys %{$watches};
    is(scalar @keys,              1,      "one file in watches");
    is(ref($watches->{$keys[0]}), 'CODE', "watch value is a coderef");

    # duplicate watch dies
    like(
        dies {
            $stage->watch($tmpfile, sub { })
        },
        qr/already a watch/,
        "dies when watching same file twice"
    );

    # non-existent file dies
    like(
        dies {
            $stage->watch('/does/not/exist/fake_file.pm', sub { })
        },
        qr/must be a file/,
        "dies for non-existent file"
    );

    # missing callback dies
    like(
        dies { $stage->watch($tmpfile, 'not a coderef') },
        qr/callback/,
        "dies when callback is not a coderef"
    );
};

subtest 'reload_inplace_check attribute' => sub {
    my $cb    = sub { 1 };
    my $stage = Test2::Harness2::Preload::Stage->new(
        name                 => 'InplaceCheck',
        reload_inplace_check => $cb,
    );
    is($stage->reload_inplace_check, $cb, "reload_inplace_check attribute stored");

    my $stage2 = Test2::Harness2::Preload::Stage->new(name => 'NoInplace');
    ok(!defined $stage2->reload_inplace_check, "reload_inplace_check is undef by default");
};

done_testing;

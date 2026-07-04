use v5.38;
# HARNESS-DURATION-SHORT

use Test2::V0;

use Test2::Harness2::Runner::Preload();
use Test2::Harness2::Runner::Preloader();

# Ticket TODO-78. The load-order DSL closures (default/pre_fork/post_fork/pre_launch/
# preload/reload_remove_check/reload_inplace_check) share a single hoisted
# $current_stage helper instead of each repeating the
# `croak "No current stage" unless @{stack}; my $stage = stack->[-1]` preamble.
# Behavior must be identical: croak outside a stage() coderef, operate on the
# active stage inside one. `launch_stage` no longer re-resolves a stage name --
# it asserts its caller handed it a resolved ref or 'NOPRELOAD'.

# A consumer that pulls in the DSL exports.
package My::Preload::Consumer {
    BEGIN { Test2::Harness2::Runner::Preload->import }
}

subtest closures_croak_outside_a_stage => sub {
    like(dies { My::Preload::Consumer::default() },              qr/No current stage/, "default croaks with no active stage");
    like(dies { My::Preload::Consumer::preload('X') },           qr/No current stage/, "preload croaks with no active stage");
    like(dies { My::Preload::Consumer::pre_fork(sub { }) },      qr/No current stage/, "pre_fork croaks with no active stage");
    like(dies { My::Preload::Consumer::post_fork(sub { }) },     qr/No current stage/, "post_fork croaks with no active stage");
    like(dies { My::Preload::Consumer::pre_launch(sub { }) },    qr/No current stage/, "pre_launch croaks with no active stage");
    like(dies { My::Preload::Consumer::reload_remove_check(sub { }) },  qr/No current stage/, "reload_remove_check croaks with no active stage");
    like(dies { My::Preload::Consumer::reload_inplace_check(sub { }) }, qr/No current stage/, "reload_inplace_check croaks with no active stage");
};

subtest closures_operate_on_active_stage => sub {
    my $rr = sub { 'remove' };
    my $ri = sub { 'inplace' };

    My::Preload::Consumer::stage(foo => sub {
        My::Preload::Consumer::preload('My::Mod');
        My::Preload::Consumer::pre_fork(sub { 'pf' });
        My::Preload::Consumer::post_fork(sub { 'post' });
        My::Preload::Consumer::pre_launch(sub { 'pl' });
        My::Preload::Consumer::reload_remove_check($rr);
        My::Preload::Consumer::reload_inplace_check($ri);
        My::Preload::Consumer::default();
    });

    my $meta  = My::Preload::Consumer::TEST2_HARNESS_PRELOAD();
    my $stage = $meta->stage_lookup->{foo};

    ok($stage, "stage 'foo' was built");
    is($meta->default_stage, 'foo', "default() set the active stage as the default (by name)");
    is($stage->load_sequence, ['My::Mod'], "preload() appended to the active stage's load sequence");
    is(scalar(@{$stage->pre_fork_callbacks}),   1, "pre_fork registered on the active stage");
    is(scalar(@{$stage->post_fork_callbacks}),  1, "post_fork registered on the active stage");
    is(scalar(@{$stage->pre_launch_callbacks}), 1, "pre_launch registered on the active stage");
    is($stage->reload_remove_check,  $rr, "reload_remove_check set on the active stage");
    is($stage->reload_inplace_check, $ri, "reload_inplace_check set on the active stage");
};

subtest launch_stage_asserts_resolved_arg => sub {
    my $pre = Test2::Harness2::Runner::Preloader->new(dir => '/tmp');

    like(
        dies { $pre->launch_stage('some-unresolved-name') },
        qr/launch_stage requires a resolved StageConfig or 'NOPRELOAD'/,
        "launch_stage confesses when handed an unresolved plain name (contract now enforced by the caller)",
    );
};

done_testing;

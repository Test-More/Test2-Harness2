use Test2::V0;
# HARNESS-DURATION-SHORT

# #116: submissions buffered while the scheduler is briefly NOT ready must be flushed
# once readiness returns. flush_submit_buffer used to fire exactly ONCE -- right after
# the initial stage-map wait in run_scheduler_only. Readiness can regress AFTER that
# (a stage peer drops during a monitor-preloads tree reload, then re-registers): the
# common "save a preloaded source file, then immediately `yath test`" sequence lands
# the submission inside that stage-downtime window, so submit_action buffers the
# queue_run/queue_task/end_queue frames and nothing ever flushes them again -- the run
# is never queued, the runner idles, and the client hangs forever with no error.
#
# This drives the REAL Runner submit_action / flush_submit_buffer /
# _flush_submit_buffer_if_ready against fake peers + a recording State, covering:
#   * the per-action flush (submit_action drains before applying a new action),
#   * the per-tick flush (the run-loop helper drains a lone buffered end_queue), and
#   * the partial-buffer ordering hazard (a late frame must never apply ahead of the
#     frames buffered while the window was open).

use Test2::Harness2::Runner;

# Minimal live-connection stand-in: _has_live_stage_peer reads only ->closed.
{
    package FakeConn;
    sub new    { my ($c, %a) = @_; bless {closed => $a{closed} // 0}, $c }
    sub closed { $_[0]->{closed} ? 1 : 0 }
}

# Recording State: logs every mutation submit_action/flush replays, in order.
{
    package RecState;
    our $AUTOLOAD;
    sub new { bless {log => []}, shift }
    sub log { $_[0]->{log} }
    sub AUTOLOAD {
        my $self = shift;
        (my $name = $AUTOLOAD) =~ s/.*:://;
        return if $name eq 'DESTROY';
        push @{$self->{log}} => [$name, @_];
        return;
    }
}

# A scheduler-only runner (preload-root hosts the stages) with a recording State. It is
# READY when a live 'preload-<stage>' peer is connected AND the stage map was reported;
# dropping the peer models the readiness regression (a stage briefly gone mid-run).
sub mk_runner {
    my %args = @_;
    return bless {
        preload_root_hosts  => 1,
        reported_stage_data => {base => {}},    # has_reported_stage_data -> true
        service_peers       => $args{ready} ? {'preload-base' => FakeConn->new} : {},
        state               => RecState->new,
    }, 'Test2::Harness2::Runner';
}

# Flip readiness by connecting/dropping the base stage's live peer.
sub set_ready {
    my ($r, $ready) = @_;
    $r->{service_peers} = $ready ? {'preload-base' => FakeConn->new} : {};
}

subtest per_action_flush_preserves_order => sub {
    my $r = mk_runner(ready => 0);
    ok(!$r->_ready_to_schedule, "scheduler not ready (no live stage peer)");

    $r->submit_action('queue_run',  'R1');
    $r->submit_action('queue_task', 'T1');
    is($r->state->log, [], "nothing applied to State while not ready");
    is(scalar @{$r->{submit_buffer}}, 2, "both submissions buffered");

    # Readiness returns; the NEXT action to arrive must drain the buffer in order FIRST,
    # then apply itself -- never ahead of the earlier buffered frames.
    set_ready($r, 1);
    $r->submit_action('end_queue');

    is(
        $r->state->log,
        [['queue_run', 'R1'], ['queue_task', 'T1'], ['end_queue']],
        "buffered frames replayed in order, then the newly-arriving action (no reordering)",
    );
    ok(!$r->{submit_buffer}, "submit buffer emptied");
};

subtest per_tick_flush_recovers_lone_end_queue => sub {
    my $r = mk_runner(ready => 0);

    # Even a lone buffered end_queue hangs the runner (State::done requires QUEUE_ENDED),
    # and no later action need arrive to trigger the per-action flush -- so the run loop's
    # per-tick helper is the only thing that can recover it.
    $r->submit_action('end_queue');
    is(scalar @{$r->{submit_buffer}}, 1, "end_queue buffered during the downtime window");

    # Still not ready: the per-tick helper must NOT flush (submissions wait for a stage).
    $r->_flush_submit_buffer_if_ready;
    is($r->state->log, [], "not flushed while readiness is still regressed");
    is(scalar @{$r->{submit_buffer}}, 1, "buffered end_queue retained");

    # Readiness restored: the per-tick helper drains it with no new action arriving.
    set_ready($r, 1);
    $r->_flush_submit_buffer_if_ready;
    is($r->state->log, [['end_queue']], "lone buffered end_queue applied once ready");
    ok(!$r->{submit_buffer}, "submit buffer emptied");
};

subtest no_preload_passthrough_never_buffers => sub {
    # No preload-root hosting -> submit_action is a straight passthrough to State and
    # must never create a buffer (the fix must not touch the no-preload path).
    my $r = bless {state => RecState->new}, 'Test2::Harness2::Runner';
    ok(!$r->_preload_root_hosts_stages, "no preload-root hosting stages");

    $r->submit_action('queue_run', 'R9');
    is($r->state->log, [['queue_run', 'R9']], "applied immediately");
    ok(!$r->{submit_buffer}, "no buffer created on the passthrough path");
};

done_testing;

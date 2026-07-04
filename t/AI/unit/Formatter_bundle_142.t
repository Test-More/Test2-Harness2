use Test2::V0;
use v5.38;

use Test2::Formatter::Test2;
use Test2::Formatter::QVF;
use Test2::Harness2::Util::Term qw/USE_ANSI_COLOR/;

# Ticket TODO-142 (P3) display-defect bundle. The Composer sub-items (54/55/56) are
# owned by cleanup TODO-64; the items exercised here are the ones TODO-142 itself keeps:
#   * (51)  QVF event count double-counts buffered/forwarded events -> the status
#           bar 'Events: N' inflates toward 2x.
#   * (101) A to-be-retried failure is counted in F permanently and todo goes
#           negative -- [P:1|F:1|T:-1] on a run that ultimately PASSES.
#   * (102) DESTROY writes an ANSI reset (\e[0m) to non-color output.

sub new_qvf {
    my $buf = '';
    open(my $fh, '>', \$buf) or die "could not open in-memory fh: $!";
    my $fmt = Test2::Formatter::QVF->new(
        io       => $fh,
        tty      => 0,    # no status-bar writes; we only care about the count
        progress => 0,
        color    => 0,
        verbose  => 0,    # REAL_VERBOSE=0 -> the buffering (quiet) path
    );
    return ($fmt, \$buf);
}

sub new_formatter {
    my (%args) = @_;
    my $buf = '';
    open(my $fh, '>', \$buf) or die "could not open in-memory fh: $!";
    my $fmt = Test2::Formatter::Test2->new(
        io       => $fh,
        tty      => 0,
        progress => 0,
        color    => 0,
        verbose  => 1,
        %args,
    );
    return ($fmt, \$buf);
}

# Pre-register the job name the way harness_job_queued would, without routing a
# run-level (no-job_id) event through write() -- keeps the count deterministic
# and the output free of pre-existing render_tree/no-job noise unrelated to TODO-142.
sub register_job {
    my ($fmt, $id) = @_;
    $fmt->{Test2::Formatter::Test2::JOB_NAMES()}{$id} = $id;
    return;
}

subtest 'QVF counts each processed event exactly once on a failing (replayed) run' => sub {
    my ($fmt, $buf) = new_qvf();
    register_job($fmt, 'j1');

    # Two buffered assertions then a failing end for the same job. The failing
    # end triggers a replay of the whole buffer through SUPER::write.
    $fmt->write(undef, undef, {harness => {job_id => 'j1'}, assert => {pass => 1, details => 'a'}});
    $fmt->write(undef, undef, {harness => {job_id => 'j1'}, assert => {pass => 1, details => 'b'}});
    $fmt->write(undef, undef, {harness => {job_id => 'j1'}, harness_job_end => {fail => 1, file => 't/x.t'}});

    is($fmt->ecount, 3, "ecount matches the 3 processed events (was ~6 before the save/restore fix)");
};

subtest 'QVF does not double-count a passing job-end' => sub {
    my ($fmt, $buf) = new_qvf();
    register_job($fmt, 'j2');

    # A passing end is forwarded once through SUPER::write; it must still count once.
    $fmt->write(undef, undef, {harness => {job_id => 'j2'}, assert => {pass => 1, details => 'c'}});
    $fmt->write(undef, undef, {harness => {job_id => 'j2'}, harness_job_end => {fail => 0, file => 't/y.t'}});

    is($fmt->ecount, 2, "passing job-end counted once, not twice");
};

subtest 'retry status counters settle at F:0 / T:0 on a run that passes on retry' => sub {
    my ($fmt, $buf) = new_formatter();

    # queue -> launch -> fail-with-retry -> relaunch -> pass
    $fmt->update_active_disp({harness_job_queued => {job_id => 'j1', job_name => 'j1'}});
    $fmt->update_active_disp({harness_job_launch => {}, harness_job => {file => 't/x.t', job_id => 'j1', job_name => 'j1'}});
    $fmt->update_active_disp({harness_job_end => {fail => 1, retry => 1, file => 't/x.t'}});
    $fmt->update_active_disp({harness_job_launch => {}, harness_job => {file => 't/x.t', job_id => 'j1', job_name => 'j1'}});
    $fmt->update_active_disp({harness_job_end => {fail => 0, file => 't/x.t'}});

    my $status = $fmt->render_status;
    like($status, qr/\[P:1\|F:0\|R:0\|T:0\]/, "counters end at [P:1|F:0|R:0|T:0] (was [P:1|F:1|R:0|T:-1])");
};

subtest 'a genuine terminal failure is still counted in F' => sub {
    my ($fmt, $buf) = new_formatter();

    $fmt->update_active_disp({harness_job_queued => {job_id => 'j1', job_name => 'j1'}});
    $fmt->update_active_disp({harness_job_launch => {}, harness_job => {file => 't/x.t', job_id => 'j1', job_name => 'j1'}});
    $fmt->update_active_disp({harness_job_end => {fail => 1, file => 't/x.t'}});

    my $status = $fmt->render_status;
    like($status, qr/\[P:0\|F:1\|R:0\|T:0\]/, "a non-retried failure still increments F");
};

subtest 'DESTROY emits no ANSI reset on non-color output' => sub {
    my $buf = '';
    open(my $fh, '>', \$buf) or die "could not open in-memory fh: $!";
    my $fmt = Test2::Formatter::Test2->new(io => $fh, tty => 0, color => 0, verbose => 1);
    undef $fmt;    # trigger DESTROY

    unlike($buf, qr/\e\[/, "no escape byte written to --no-color output on DESTROY");
};

subtest 'DESTROY still resets color on a color-enabled formatter' => sub {
    plan skip_all => "Term::ANSIColor >= 4.03 not available" unless USE_ANSI_COLOR;

    my $buf = '';
    open(my $fh, '>', \$buf) or die "could not open in-memory fh: $!";
    my $fmt = Test2::Formatter::Test2->new(io => $fh, tty => 0, color => 1, verbose => 1);
    undef $fmt;    # trigger DESTROY

    like($buf, qr/\e\[/, "color formatter still emits the reset escape on DESTROY");
};

done_testing;

use Test2::V0;

# Ticket #133: -L DB loggers were silently SIGTERM'd at the teardown timeout and
# their exit status was never checked, so a truncated (or outright failed) DB
# import left yath exiting 0 with no word to the user.
#
# wait_for_loggers now, command-side:
#   * warns (naming pid + -L target) on a logger that exits nonzero within the
#     window -- the failed/partial import is surfaced, not swallowed;
#   * on the timeout, warns the import may be truncated, TERMs the straggler, and
#     BLOCKING-reaps it so no zombie is left behind.
# (#132 owns the logger-SIDE 'broken' DB marking; this drives only the command
# side, so no DB deps are needed here.)

use POSIX ();

BEGIN { require App::Yath2::Command::test }

# A test subclass so we can shorten the teardown window (a real slow logger is not
# needed -- a sleeper past a 1s window exercises the same path) and drive
# wait_for_loggers directly with pids/targets we control.
{
    package t2h2::WaitCmd;
    our @ISA = ('App::Yath2::Command::test');
    sub new                 { my ($c, %a) = @_; bless {%a}, $c }
    sub logger_wait_timeout { $_[0]->{wait_timeout} // 1 }
    sub settings            { $_[0]->{settings} }
    sub workdir             { $_[0]->{workdir} }
    sub run_id              { $_[0]->{run_id} }
}

use constant PIDS    => App::Yath2::Command::test::LOGGER_PIDS();
use constant TARGETS => App::Yath2::Command::test::LOGGER_TARGETS();

# Fork a child that runs $code then _exit(0); _exit bypasses END blocks so a forked
# child never re-enters the Test2 test framework.
sub spawn_child {
    my ($code) = @_;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    unless ($pid) {
        $code->();
        POSIX::_exit(0);
    }
    return $pid;
}

# Collect warnings emitted while $code runs.
sub warns_from {
    my ($code) = @_;
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0] };
    my $ret = $code->();
    return (\@warns, $ret);
}

subtest 'no loggers -> no-op, returns 0' => sub {
    my $cmd = t2h2::WaitCmd->new;
    my ($warns, $ret) = warns_from(sub { $cmd->wait_for_loggers });
    is($ret, 0, "returns 0 failed loggers");
    is($warns, [], "no warnings");
};

subtest 'clean exit within the window -> no warning' => sub {
    my $pid = spawn_child(sub { POSIX::_exit(0) });
    my $cmd = t2h2::WaitCmd->new(
        wait_timeout => 30,
        PIDS()       => [$pid],
        TARGETS()    => {$pid => 'db.sqlite'},
    );

    my ($warns, $ret) = warns_from(sub { $cmd->wait_for_loggers });
    is($ret, 0, "no failed loggers");
    is($warns, [], "a cleanly-exiting logger produces no warning");
    is($cmd->{PIDS()}, [], "logger pid list cleared");
};

subtest 'nonzero exit within the window -> warning naming pid + target' => sub {
    my $pid = spawn_child(sub { POSIX::_exit(3) });
    my $cmd = t2h2::WaitCmd->new(
        wait_timeout => 30,
        PIDS()       => [$pid],
        TARGETS()    => {$pid => 'db.sqlite'},
    );

    my ($warns, $ret) = warns_from(sub { $cmd->wait_for_loggers });
    is($ret, 1, "one failed logger reported");
    is(scalar(@$warns), 1, "exactly one warning");
    like($warns->[0], qr/DB logger \Q$pid\E/,      "warning names the pid");
    like($warns->[0], qr/-L db\.sqlite/,           "warning names the -L target");
    like($warns->[0], qr/exit 3/,                  "warning reports the nonzero exit code");
    like($warns->[0], qr/import may be incomplete|import.*failed/i, "warning flags the truncated/failed import");
};

subtest 'straggler past the timeout -> warned, TERMd, and blocking-reaped' => sub {
    my $pid = spawn_child(sub {
        $SIG{TERM} = 'DEFAULT';    # let the harness TERM actually kill us
        sleep 30;
        POSIX::_exit(0);
    });

    my $cmd = t2h2::WaitCmd->new(
        wait_timeout => 1,         # short window: the sleeper outruns it
        PIDS()       => [$pid],
        TARGETS()    => {$pid => 'remote.pg'},
    );

    my ($warns, $ret) = warns_from(sub { $cmd->wait_for_loggers });
    is($ret, 1, "the TERMd straggler counts as failed/incomplete");
    is(scalar(@$warns), 1, "exactly one warning");
    like($warns->[0], qr/DB logger \Q$pid\E/,    "warning names the straggler pid");
    like($warns->[0], qr/-L remote\.pg/,         "warning names the -L target");
    like($warns->[0], qr/did not finish within 1s/, "warning states the timeout window");
    like($warns->[0], qr/truncated/,             "warning flags a possibly-truncated import");

    # Blocking-reaped: it is neither alive nor a lingering zombie. A further
    # waitpid must report -1 (ECHILD: already reaped), not the pid.
    is(waitpid($pid, POSIX::WNOHANG()), -1, "pid was reaped, no zombie left behind");
    is($cmd->{PIDS()}, [], "logger pid list cleared");
};

subtest 'start_loggers records a pid->target map for teardown' => sub {
    # Mirror DB_Logger_project.t: mock run_cmd so no real logger spawns, and assert
    # the pid->target mapping (the input wait_for_loggers names failures from) is
    # populated.
    package t2h2::FL { sub new { my ($c, %a) = @_; bless {%a}, $c } sub targets { $_[0]->{targets} } }
    package t2h2::FH { sub new { my ($c, %a) = @_; bless {%a}, $c } sub project { $_[0]->{project} } sub dev_libs { $_[0]->{dev_libs} } }
    package t2h2::FS { sub new { my ($c, %a) = @_; bless {%a}, $c } sub check_group { $_[0]->{groups}{$_[1]} ? 1 : 0 } sub logger { $_[0]->{logger} } sub harness { $_[0]->{harness} } }

    my $settings = t2h2::FS->new(
        groups  => {logger => 1, harness => 1},
        logger  => t2h2::FL->new(targets => ['a.sqlite', 'b.sqlite']),
        harness => t2h2::FH->new(project => undef, dev_libs => []),
    );

    my $cmd = t2h2::WaitCmd->new(
        settings => $settings,
        workdir  => '/tmp/yath-xxxx',
        run_id   => 'abc-123',
    );

    my $next = 100;
    my @cfg_files;
    no warnings 'redefine', 'once';
    local *Test2::Harness2::Util::IPC::run_cmd = sub { my %a = @_; push @cfg_files, $a{command}[-1]; return $next++ };
    $cmd->start_loggers;
    unlink($_) for @cfg_files;    # tempfiles written UNLINK => 0

    is($cmd->{PIDS()}, [100, 101], "both logger pids recorded in order");
    is($cmd->{TARGETS()}, {100 => 'a.sqlite', 101 => 'b.sqlite'}, "pid->target map recorded");
}
    if eval { require Test2::Harness2::Util::IPC; require Cwd; 1 };

done_testing;

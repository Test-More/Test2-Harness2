use Test2::V0;

# Regression coverage for ticket TODO-146 (persist-command UX bundle), all exercised
# WITHOUT starting a real runner by mocking discovery/client/method seams:
#
#   (5)   test.pm    -- an interrupted run reports honestly, runs plugin finish()
#                       hooks with partial results, and re-raises the signal
#                       (128+signum) instead of the "Final data never received" die.
#   (18)  resources  -- the render loop breaks (does not clear the screen forever)
#                       once the runner goes away.
#   (71)  status/ps  -- pid columns holding 'N/A' no longer spray "isn't numeric"
#                       warnings through the numeric sorts.
#   (73)  ps         -- ps attaches the client to the discovered pid before asking
#                       for status.
#   (103) ping       -- a no-response ping exits 1 (and does not print "Stopped.");
#                       a real interrupt still exits 0 with "Stopped.".
#   (G11) reload/stop -- a live socket with a missing/garbled PID file dies with the
#                       named-workdir message rather than crashing on kill(undef).

use POSIX ();

require App::Yath2::Command::test;
require App::Yath2::Command::status;
require App::Yath2::Command::ps;
require App::Yath2::Command::ping;
require App::Yath2::Command::reload;
require App::Yath2::Command::stop;
require App::Yath2::Command::resources;
require App::Yath2::Discovery;
require App::Yath2::Client;

# ---- small stand-ins -------------------------------------------------------

# A Discovery-shaped object; commands read ->pid and ->workdir (and _stop_live).
{
    package t::FakeDisco;
    sub new     { bless $_[1], $_[0] }
    sub pid     { $_[0]->{pid} }
    sub workdir { $_[0]->{workdir} }
}

# A runner client that records attach_runner and hands back a canned status.
{
    package t::Client;
    sub new           { my ($c, %a) = @_; bless {%a, attached => []}, $c }
    sub attach_runner { my ($self, $pid) = @_; push @{$self->{attached}}, $pid; 1 }
    sub status        { $_[0]->{status} }
}

# A ping client: attach is a no-op, ping returns the canned reply.
{
    package t::PingDisco;
    sub new      { bless {}, shift }
    sub describe { "FAKE DISCO\n" }
    sub workdir  { '/fake/workdir' }
    sub pid      { 4321 }

    package t::PingClient;
    sub new           { my ($c, %a) = @_; bless {%a}, $c }
    sub attach_runner { 1 }
    sub ping          { $_[0]->{reply} }
}

# A plugin whose finish() records the args it was handed.
{
    package t::Plugin;
    sub new    { bless {calls => $_[1]}, $_[0] }
    sub finish { my $self = shift; push @{$self->{calls}}, {@_} }
}

# test.pm subclass whose signal re-raise is neutered so a non-forked test survives.
{
    package t::NoReraise;
    our @ISA = ('App::Yath2::Command::test');
    sub _reraise_signal { return }
}

# test.pm subclass driving the interrupted run() end-to-end in a forked child.
{
    package t::Settings;
    sub harness { $_[0] }
    sub plugins { [] }

    package t::IntTest;
    our @ISA = ('App::Yath2::Command::test');
    sub start                  { 1 }
    sub render                 { my $self = shift; $self->{tests_seen} = 2; $self->{asserts_seen} = 5; $self->{final_data} = undef; return }
    sub stop                   { return }
    sub signal                 { 'INT' }
    sub remove_signal_handlers { return }    # avoid building a real client for cleanup
}

# ---- (103) ping exit code --------------------------------------------------

subtest ping_no_response_exit_1 => sub {
    my $client = t::PingClient->new(reply => undef);

    no warnings qw/redefine once/;
    local *App::Yath2::Discovery::find = sub { t::PingDisco->new };
    local *App::Yath2::Client::new     = sub { $client };

    my $cmd = bless {settings => {}}, 'App::Yath2::Command::ping';

    my ($out, $ret) = ('', undef);
    {
        local *STDOUT;
        open(STDOUT, '>', \$out) or die "STDOUT: $!";
        $ret = $cmd->run;
    }

    is($ret, 1, "no response from the runner => exit 1 (health checks must not proceed)");
    like($out, qr/no response from runner/, "prints the no-response diagnostic");
    unlike($out, qr/Stopped\./, "does NOT print the clean-stop banner on failure");
};

subtest ping_interrupt_exit_0 => sub {
    my $client = bless {}, 't::PingClient';

    no warnings qw/redefine once/;
    # ping interrupts the loop the way Ctrl-C would (run() installs a local INT
    # handler that flips its $stop), then returns a normal reply.
    local *t::PingClient::ping         = sub { kill('INT', $$); return {pid => 4321} };
    local *App::Yath2::Discovery::find = sub { t::PingDisco->new };
    local *App::Yath2::Client::new     = sub { $client };

    my $cmd = bless {settings => {}}, 'App::Yath2::Command::ping';

    my ($out, $ret) = ('', undef);
    {
        local *STDOUT;
        open(STDOUT, '>', \$out) or die "STDOUT: $!";
        $ret = $cmd->run;
    }

    is($ret, 0, "a clean interrupt still exits 0");
    like($out, qr/Stopped\./, "prints the clean-stop banner on interrupt");
};

# ---- (G11) reload / stop undef-pid guard -----------------------------------

subtest reload_undef_pid_dies => sub {
    my $cmd = bless {settings => {}}, 'App::Yath2::Command::reload';

    no warnings qw/redefine once/;
    local *App::Yath2::Discovery::find = sub {
        t::FakeDisco->new({pid => undef, workdir => '/gone/workdir'});
    };

    my $ok = eval { $cmd->run; 1 };
    my $err = $@;

    ok(!$ok, "reload dies when the workdir PID file is missing/unreadable");
    like($err, qr/PID file is missing/,   "message reports the missing PID file");
    like($err, qr{/gone/workdir},          "message names the workdir");
    like($err, qr/restart the runner/,     "message tells the user to restart the runner");
};

subtest stop_undef_pid_dies => sub {
    my $cmd = bless {settings => {}}, 'App::Yath2::Command::stop';
    my $disco = t::FakeDisco->new({pid => undef, workdir => '/gone/workdir'});

    my $ok = eval { $cmd->_stop_live($disco); 1 };
    my $err = $@;

    ok(!$ok, "_stop_live dies when the workdir PID file is missing/unreadable");
    like($err, qr/PID file is missing/, "message reports the missing PID file");
    like($err, qr{/gone/workdir},        "message names the workdir");
};

# ---- (18) resources runner-gone break --------------------------------------

subtest resources_runner_gone_breaks_loop => sub {
    my $n = 0;

    no warnings qw/redefine once/;
    local *App::Yath2::Command::resources::runner_resources = sub {
        $n++;
        die "runner_resources called too many times ($n): loop did not break on runner-gone\n"
            if $n > 20;
        return [] if $n == 1;    # up-front probe succeeds
        return undef;            # runner gone on the first in-loop read
    };

    my $cmd = bless {}, 'App::Yath2::Command::resources';

    my ($out, $ret) = ('', undef);
    {
        local *STDOUT;
        open(STDOUT, '>', \$out) or die "STDOUT: $!";
        $ret = $cmd->run;
    }

    is($ret, 0, "returns 0 once the runner goes away");
    like($out, qr/Runner has gone away/, "reports that the runner went away");
    ok($n <= 3, "broke out of the loop promptly (runner_resources called $n times)");
};

# ---- (71/73) status / ps N/A pid sort + ps attach --------------------------

subtest status_na_pid_no_warnings => sub {
    my $status = {
        runs            => [],
        stage_lifecycle => {base => {state => 'up'}, restart => {state => 'restarting'}},
        stage_pids      => {base => 12345},    # 'restart' has no pid => 'N/A'
        reload_state    => {},
        running         => [
            {pid => 999, job_id => 'j1', is_try => 0, rel_file => 't/a.t', conflicts => []},
            {job_id => 'j2', is_try => 0, rel_file => 't/b.t', conflicts => []},    # no pid => 'N/A'
        ],
    };

    my $client = t::Client->new(status => $status);
    my $cmd = bless {client => $client}, 'App::Yath2::Command::status';

    no warnings qw/redefine once/;
    local *App::Yath2::Command::status::pfile_data = sub { {pid => 4321, dir => '/x', pfile_path => '/x/link'} };

    my (@warn, $out, $ret);
    {
        local $SIG{__WARN__} = sub { push @warn, $_[0] };
        local *STDOUT;
        open(STDOUT, '>', \$out) or die "STDOUT: $!";
        $ret = $cmd->run;
    }

    is($ret, 0, "status run returns 0");
    is($client->{attached}[0], 4321, "status attached the client to the discovered pid");
    my @numeric = grep { /isn't numeric/ } @warn;
    is(scalar(@numeric), 0, "no 'isn't numeric' warnings sorting pid columns containing 'N/A'")
        or diag(join("\n", @numeric));
};

subtest ps_na_pid_and_attach => sub {
    my $status = {
        stage_lifecycle => {s1 => {state => 'up'}, s2 => {state => 'up'}},
        stage_pids      => {s1 => 100},    # s2 up but no pid => 'N/A'
        running         => [
            {pid => 200, rel_file => 't/a.t'},
            {rel_file => 't/b.t'},          # no pid => 'N/A'
        ],
    };

    my $client = t::Client->new(status => $status);
    my $cmd = bless {client => $client}, 'App::Yath2::Command::ps';

    no warnings qw/redefine once/;
    local *App::Yath2::Command::ps::pfile_data = sub { {pid => 4321, dir => '/x', pfile_path => '/x/link'} };

    my (@warn, $out, $ret);
    {
        local $SIG{__WARN__} = sub { push @warn, $_[0] };
        local *STDOUT;
        open(STDOUT, '>', \$out) or die "STDOUT: $!";
        $ret = $cmd->run;
    }

    is($ret, 0, "ps run returns 0");
    is($client->{attached}[0], 4321, "ps now attaches the client to the discovered pid (TODO-73)");
    my @numeric = grep { /isn't numeric/ } @warn;
    is(scalar(@numeric), 0, "no 'isn't numeric' warnings in the ps pid sort")
        or diag(join("\n", @numeric));
};

# ---- (5) interrupted test run ----------------------------------------------

subtest interrupted_runs_plugin_finish => sub {
    my @calls;
    my $plugin = t::Plugin->new(\@calls);

    my $cmd = bless {
        settings     => 'SETTINGS',
        tests_seen   => 2,
        asserts_seen => 5,
        final_data   => {pass => 0},
    }, 't::NoReraise';

    my $err = '';
    {
        local *STDERR;
        open(STDERR, '>', \$err) or die "STDERR: $!";
        $cmd->_finish_interrupted('INT', [$plugin]);
    }

    like($err, qr/Run interrupted by SIGINT/, "prints an honest interrupted banner");
    is(scalar(@calls), 1, "plugin finish() hook still runs on a signal");
    is($calls[0]{tests_seen}, 2, "plugin finish() gets the partial tests_seen");
    is($calls[0]{pass},       0, "interrupted run is reported as not-passing");
};

subtest interrupted_reraises_signal => sub {
    pipe(my ($rh, $wh)) or die "pipe: $!";

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    unless ($pid) {
        # Child: drive the interrupted run() end-to-end; it must re-raise SIGINT.
        close $rh;
        open(STDERR, '>&', $wh) or POSIX::_exit(50);
        open(STDOUT, '>&', $wh) or POSIX::_exit(50);

        my $cmd = bless {settings => bless({}, 't::Settings'), tests_seen => 0}, 't::IntTest';
        eval { $cmd->run };
        # Only reached if the signal did not terminate us: surface it distinctly.
        print STDERR "REACHED-AFTER-RUN\n";
        POSIX::_exit(42);
    }

    close $wh;
    my $out = do { local $/; <$rh> };
    close $rh;
    waitpid($pid, 0);
    my $status = $?;

    my $by_signal = ($status & 127) == POSIX::SIGINT();
    my $by_code   = ($status & 127) == 0 && ($status >> 8) == 128 + POSIX::SIGINT();
    ok($by_signal || $by_code, "child exits with the 128+SIGINT convention (signal death or exit code)")
        or diag("wait status: $status");

    like($out, qr/Run interrupted by SIGINT/, "prints the interrupted banner");
    unlike($out, qr/Final data never received/, "no internal 'Final data never received' die on interrupt");
    unlike($out, qr/REACHED-AFTER-RUN/, "the run() tail after the interrupt branch is not reached");
};

done_testing;

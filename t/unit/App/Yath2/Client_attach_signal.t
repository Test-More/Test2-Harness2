use Test2::V0 -target => 'App::Yath2::Client';
use Test2::Tools::Spec;

use App::Yath2::Client;

# Regression: #122 -- Ctrl-C on `yath run` (attach mode) was unhandled, so the
# command died instantly: the terminal-reset renderer never ran (dirty terminal),
# a `-F` log was left without its `null` terminator, and the DB loggers died
# mid-import. attach mode must now INSTALL signal handlers and, on a caught signal,
# stop the render loop + halt just this run over the socket so the command's stop()
# runs its graceful teardown (flush renderers/logs, reset the terminal, drain the
# loggers) -- WITHOUT ever signalling the shared persistent runner.

sub attach_client {
    my %args = @_;
    my $client = App::Yath2::Client->new(
        workdir   => '/tmp/wd',
        mode      => 'attach',
        on_signal => $args{on_signal} // sub { },
    );
    $client->attach_runner($args{pid} // $$);
    return $client;
}

tests attach_installs_handlers => sub {
    local %SIG = %SIG;
    delete @SIG{qw/INT HUP TERM/};

    my $client = attach_client();
    $client->install_signal_handlers;

    ok(ref($SIG{$_}) eq 'CODE', "attach mode installed a $_ handler") for qw/INT HUP TERM/;

    $client->remove_signal_handlers;
    ok(!ref($SIG{INT}), "remove cleared the attach INT handler");
};

tests attach_signal_is_graceful => sub {
    my (@relayed, @halted, @killed);

    no warnings 'redefine';
    # halt_run: record the run it halts (no real socket).
    local *App::Yath2::Client::halt_run = sub { push @halted => $_[0]->run_id };
    # Trip-wire: attach mode must NEVER signal the shared persistent runner.
    local *App::Yath2::Client::signal_runner = sub { push @killed => $_[1] };

    my $client = attach_client(on_signal => sub { push @relayed => $_[0] });
    $client->{+App::Yath2::Client::RUN_ID()} = 'RUN-122';

    {
        local *STDERR;
        open(STDERR, '>', '/dev/null');
        $client->handle_signal('INT');
    }

    is(\@relayed, ['INT'],      "on_signal relayed INT (stops the render loop / flushes renderers)");
    is(\@halted,  ['RUN-122'],  "attach mode asked the runner to halt just this run over the socket");
    is(\@killed,  [],           "attach mode never signals the shared persistent runner");
    is($client->signal, 'INT',  "the caught signal is recorded so stop() runs the graceful teardown");
};

tests attach_second_signal_hard_exits => sub {
    # The second Ctrl-C convention: exit immediately without waiting. Exercised in a
    # child so the exit(1) does not take the test process down.
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    unless ($pid) {
        no warnings 'redefine';
        local *App::Yath2::Client::halt_run = sub { };    # no real socket
        open(STDERR, '>', '/dev/null');

        my $client = App::Yath2::Client->new(workdir => '/tmp/wd', mode => 'attach', on_signal => sub { });
        $client->attach_runner($$);
        $client->{+App::Yath2::Client::RUN_ID()} = 'RUN-122';

        $client->handle_signal('INT');    # first: records the signal, returns
        $client->handle_signal('INT');    # second: hard-exits (exit 1)
        exit 0;                           # not reached
    }

    waitpid($pid, 0);
    is($? >> 8, 1, "a second signal in attach mode hard-exits (exit 1) without waiting");
};

done_testing;

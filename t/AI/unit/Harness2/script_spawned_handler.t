use Test2::V0;
use POSIX ();
use Time::HiRes ();
use Test2::Harness2;

my @sent;
my $client = bless { sent => \@sent }, 'TSSClient';
sub TSSClient::send_message { push @{$_[0]{sent}}, [@_[1,2]]; 1 }

subtest 'script_spawned records child pid on pending entry' => sub {
    my $h = bless {
        Test2::Harness2::PENDING_SCRIPT_SPAWNS() => {
            7 => { notify_to => 'yath-spawn-9999', stage => 'BASE', preload_pid => 1234 },
        },
        Test2::Harness2::NAME() => 'harness',
        _CLIENT_MOCK            => $client,
    }, 'Test2::Harness2';
    no warnings 'redefine';
    local *Test2::Harness2::client = sub { $_[0]->{_CLIENT_MOCK} };

    $h->_handle_script_spawned({ kind => 'script_spawned', spawn_id => 7, pid => 55555 });

    is($h->{Test2::Harness2::PENDING_SCRIPT_SPAWNS()}{7}{child_pid}, 55555,
        'child pid recorded');
};

subtest 'poll_script_exits sends script_exited and clears pending' => sub {
    my @sent2;
    my $client2 = bless { sent => \@sent2 }, 'TSSClient';
    my $kid = fork // die "fork: $!";
    if (!$kid) { POSIX::_exit(42) }
    Time::HiRes::sleep(0.1);

    my $h2 = bless {
        Test2::Harness2::PENDING_SCRIPT_SPAWNS() => {
            8 => { notify_to => 'cli-1', child_pid => $kid },
        },
        Test2::Harness2::NAME() => 'harness',
        _CLIENT_MOCK            => $client2,
    }, 'Test2::Harness2';
    no warnings 'redefine';
    local *Test2::Harness2::client = sub { $_[0]->{_CLIENT_MOCK} };

    $h2->_poll_script_exits;

    is(scalar(@sent2), 1, 'one notification sent');
    is($sent2[0][0], 'cli-1', 'sent to notify_to');
    is($sent2[0][1]{kind}, 'script_exited', 'kind=script_exited');
    is($sent2[0][1]{exit}, 42, 'exit code forwarded');
    is($h2->{Test2::Harness2::PENDING_SCRIPT_SPAWNS()}{8}, undef,
        'pending entry cleared');
};

subtest 'poll_script_exits leaves still-running entries alone' => sub {
    my $h3 = bless {
        Test2::Harness2::PENDING_SCRIPT_SPAWNS() => {
            9 => { notify_to => 'cli-2', child_pid => $$ },
        },
        Test2::Harness2::NAME() => 'harness',
        _CLIENT_MOCK            => bless { sent => [] }, 'TSSClient',
    }, 'Test2::Harness2';
    no warnings 'redefine';
    local *Test2::Harness2::client = sub { $_[0]->{_CLIENT_MOCK} };

    $h3->_poll_script_exits;
    ok($h3->{Test2::Harness2::PENDING_SCRIPT_SPAWNS()}{9}, 'still pending');
};

done_testing;

use Test2::V0;
use App::Yath2::Util::IPC qw/assert_daemon_alive/;

# Missing pid dies with a clear message that names the IPC info file.
like(
    dies { assert_daemon_alive({ _path => '/tmp/fake.json' }) },
    qr{IPC info file '/tmp/fake.json' is missing the harness pid},
    'missing pid is rejected and names the IPC info file',
);

# Live pid passes silently.
assert_daemon_alive({ pid => $$, _path => '/tmp/fake.json' });
pass('live pid accepted');

# Dead pid dies with stale message.
my $dead = fork;
if (!$dead) { exit 0 }
waitpid $dead, 0;
like(
    dies { assert_daemon_alive({ pid => $dead, _path => '/tmp/fake.json' }) },
    qr{harness pid \d+ is no longer running .*\Q/tmp/fake.json\E},
    'dead pid is rejected with stale-info message',
);

done_testing;

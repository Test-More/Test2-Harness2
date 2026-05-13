use Test2::V0;

use Test2::Harness2::PreloadService;

# Build a bare PreloadService and invoke the request handler directly.
# Stub out the reloader so we can assert do_reload is called.
{
    package Reloader::FakeOK;
    sub new { bless { called => 0 }, shift }
    sub do_reload { $_[0]->{called}++; return 1 }
    sub last_error { return }
}
{
    package Reloader::FakeFail;
    sub new { bless {}, shift }
    sub do_reload { die "boom\n" }
    sub last_error { return }
}

# Missing reloader: returns ok=1 no-op (nothing to reload is success,
# not failure -- reporting a failure would mislead an operator into
# thinking the daemon is broken).
my $svc = bless { _reloader => undef }, 'Test2::Harness2::PreloadService';
my $res = $svc->request_handler_reload({}, undef);
is(
    $res,
    { ok => 1, noop => 1, message => match qr/no reloader/i },
    'no reloader -> ok=1 noop',
);

# Successful reload.
my $rel = Reloader::FakeOK->new;
$svc = bless { _reloader => $rel }, 'Test2::Harness2::PreloadService';
$res = $svc->request_handler_reload({}, undef);
is($res, { ok => 1 }, 'successful reload -> ok=1');
is($rel->{called}, 1, 'do_reload called once');

# Reloader that throws -> ok=0 with the error message.
$svc = bless { _reloader => Reloader::FakeFail->new }, 'Test2::Harness2::PreloadService';
$res = $svc->request_handler_reload({}, undef);
is($res, { ok => 0, error => match qr/boom/ }, 'failed reload -> ok=0 with message');

done_testing;

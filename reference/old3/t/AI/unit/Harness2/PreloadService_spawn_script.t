use Test2::V0;
use Test2::Harness2::PreloadService;

# request_handler_spawn_script(\%payload, $msg) drops the message on
# the floor (after a warn) when any required field is missing.
# Required: script_abs, env, cwd, sock_path, spawn_id, notify_to.

subtest 'missing fields warn and return' => sub {
    my $self = bless { name => 'preload-myapp', NAME => 'preload-myapp' },
        'Test2::Harness2::PreloadService';

    for my $missing (qw/script_abs env cwd sock_path spawn_id notify_to/) {
        my %p = (
            script_abs => '/tmp/x.pl',
            env        => {},
            cwd        => '/tmp',
            sock_path  => '/tmp/spawn.sock',
            spawn_id   => 1,
            notify_to  => 'harness',
        );
        delete $p{$missing};
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $ret = $self->request_handler_spawn_script(\%p, undef);
        is($ret, undef, "missing $missing returns undef");
        like("@warnings", qr/\Q$missing\E/, "missing $missing warns");
    }
};

done_testing;

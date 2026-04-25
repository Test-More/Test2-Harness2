use Test2::V0;
use App::Yath2::Util::IPC qw/resolve_ipc_filename/;

is(
    resolve_ipc_filename(
        type    => 'nonce',
        host    => 'darkstar',
        pid     => 12345,
        uuid    => 'a3f8c2e9',
        tempdir => 0,
    ),
    '.yath-nonce-darkstar-12345-a3f8c2e9',
    'normal filename has leading dot, host, pid, uuid',
);

is(
    resolve_ipc_filename(
        type    => 'nonce',
        user    => 'exodist',
        pid     => 12345,
        uuid    => 'a3f8c2e9',
        tempdir => 1,
    ),
    'yath-nonce-exodist-12345-a3f8c2e9',
    'tempdir filename has no leading dot, user replaces host',
);

is(
    resolve_ipc_filename(
        type    => 'persistent',
        host    => 'h1',
        pid     => 99,
        uuid    => 'deadbeef',
        tempdir => 0,
    ),
    '.yath-persistent-h1-99-deadbeef',
    'persistent type works the same way',
);

like(
    dies { resolve_ipc_filename(type => 'bogus', host => 'h', pid => 1, uuid => 'aaaaaaaa', tempdir => 0) },
    qr/type/,
    'rejects unknown type',
);

like(
    dies { resolve_ipc_filename(type => 'nonce', pid => 1, uuid => 'aaaaaaaa', tempdir => 0) },
    qr/host/,
    'normal form requires host',
);

like(
    dies { resolve_ipc_filename(type => 'nonce', pid => 1, uuid => 'aaaaaaaa', tempdir => 1) },
    qr/user/,
    'tempdir form requires user',
);

done_testing;

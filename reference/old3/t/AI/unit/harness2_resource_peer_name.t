use Test2::V0;
use Test2::Harness2;

my $harness = bless {}, 'Test2::Harness2';

# Global scope: just the service name.
is(
    $harness->_resource_peer_name({name => 'myres', scope => 'global'}),
    'resource-myres',
    'global-scope peer name',
);

# Run scope: includes run_id segment.
is(
    $harness->_resource_peer_name({name => 'myres', scope => 'run', run => 7}),
    'resource-7-myres',
    'run-scope peer name',
);

# Run scope without run_id: falls back to global form (defensive).
is(
    $harness->_resource_peer_name({name => 'myres', scope => 'run'}),
    'resource-myres',
    'run-scope without run defaults to global form',
);

done_testing;

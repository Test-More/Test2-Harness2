use Test2::V0;
use Test2::Harness2;

# Stubs. _spawn_service_via_preload + _ipcm_service_standalone are
# what the drain helpers dispatch to; we capture the dispatches so we
# can assert which path the queue took without involving a real fork.
my (@spawned, @standalone);
{
    no warnings 'redefine';
    *Test2::Harness2::_spawn_service_via_preload = sub {
        my (undef, $pinfo, $entry) = @_;
        push @spawned, [$pinfo->{name}, $entry->{name}];
        return 99;
    };
    *Test2::Harness2::_ipcm_service_standalone = sub {
        my (undef, %p) = @_;
        push @standalone, $p{name};
        return 'started';
    };
    *Test2::Harness2::_find_eligible_preload_service = sub {
        my ($self, $pname) = @_;
        return $self->{eligible}{$pname};
    };
    *Test2::Harness2::emit_service_event = sub { };
}

# Drain on preload_ready: a queued dependent fires through
# _spawn_service_via_preload as soon as the matching preload is
# eligible + ready.
{
    @spawned    = ();
    @standalone = ();
    my $h = bless {
        eligible                   => {},
        resources_awaiting_preload => {},
        known_preload_names        => {myapp => 1},
        run_states                 => {},
    }, 'Test2::Harness2';

    push @{$h->{resources_awaiting_preload}{myapp}} => {
        name          => 'pool',
        scope         => 'global',
        service_class => 'X',
        service_args  => {},
        resource      => bless({}, 'X'),
        log_path      => '/tmp/p',
    };

    is(scalar @spawned,    0, 'no spawn yet');
    is(scalar @standalone, 0, 'no standalone yet');

    # Preload becomes eligible + ready event arrives.
    $h->{eligible}{myapp} = {name => 'preload-myapp', pid => $$};
    $h->_handle_preload_state_message('preload_ready', {preload_name => 'myapp'});

    is(scalar @spawned, 1, 'queue drained');
    is($spawned[0], ['preload-myapp', 'pool'], 'dispatched the queued entry');
    is(scalar @{$h->{resources_awaiting_preload}{myapp} // []}, 0,
        'queue emptied');
}

# Permanent broken: flush queue through _ipcm_service_standalone so the
# dependent still gets a service, just unpreloaded.
{
    @spawned    = ();
    @standalone = ();
    my $h = bless {
        eligible                   => {},
        resources_awaiting_preload => {},
        known_preload_names        => {myapp => 1},
        run_states                 => {},
    }, 'Test2::Harness2';

    push @{$h->{resources_awaiting_preload}{myapp}} => {
        name          => 'pool',
        scope         => 'global',
        service_class => 'X',
        service_args  => {},
        resource      => bless({}, 'X'),
        log_path      => '/tmp/p',
    };

    $h->_handle_preload_state_message('preload_broken',
        {preload_name => 'myapp', permanent => 1, error => 'load failed'});

    is(scalar @spawned,    0, 'no preload spawn');
    is(scalar @standalone, 1, 'dispatched standalone');
    is($standalone[0], 'pool', 'standalone got the queued entry');
}

# Transient broken (not permanent): queue stays intact so a later
# preload_ready can still drain it.
{
    @spawned    = ();
    @standalone = ();
    my $h = bless {
        eligible                   => {},
        resources_awaiting_preload => {},
        known_preload_names        => {myapp => 1},
        run_states                 => {},
    }, 'Test2::Harness2';

    push @{$h->{resources_awaiting_preload}{myapp}} => {
        name          => 'pool',
        scope         => 'global',
        service_class => 'X',
        service_args  => {},
        resource      => bless({}, 'X'),
        log_path      => '/tmp/p',
    };

    $h->_handle_preload_state_message('preload_broken',
        {preload_name => 'myapp', permanent => 0, error => 'transient'});

    is(scalar @spawned,    0, 'no preload spawn');
    is(scalar @standalone, 0, 'no standalone yet (transient broken keeps queue)');
    is(scalar @{$h->{resources_awaiting_preload}{myapp} // []}, 1,
        'queue preserved on transient broken');
}

done_testing;

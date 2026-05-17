use Test2::V0;

use Test2::Harness2::PreloadService;

subtest 'do_preload requires each module in order' => sub {
    my $s = Test2::Harness2::PreloadService->new(
        name    => 'p',
        modules => ['Scalar::Util', 'List::Util'],
    );

    # Clear from %INC so we can observe the load.
    my @loaded;
    no warnings 'redefine';
    local *Test2::Harness2::PreloadService::_require_module = sub {
        my ($self, $mod) = @_;
        push @loaded, $mod;
        return 1;
    };

    my $ok = eval { $s->do_preload; 1 };
    ok($ok, 'do_preload completes') or diag $@;
    is(\@loaded, ['Scalar::Util', 'List::Util'], 'loaded in CLI order');
};

subtest 'do_preload croaks on first failure with module name' => sub {
    my $s = Test2::Harness2::PreloadService->new(
        name    => 'p',
        modules => ['A::OK', 'B::Bad', 'C::Skip'],
    );

    my @loaded;
    no warnings 'redefine';
    local *Test2::Harness2::PreloadService::_require_module = sub {
        my ($self, $mod) = @_;
        push @loaded, $mod;
        die "synthetic boom for $mod\n" if $mod eq 'B::Bad';
        return 1;
    };

    my $ok = eval { $s->do_preload; 1 };
    ok(!$ok, 'do_preload dies');
    like($@, qr/B::Bad/,            'error names the failing module');
    like($@, qr/preload 'p'/,       'error names the preload');
    is(\@loaded, ['A::OK', 'B::Bad'], 'stopped after the failing module');
};

subtest 'service_on_start sends preload_ready to harness' => sub {
    my $s = Test2::Harness2::PreloadService->new(
        name    => 'mypl',
        modules => [],
        scope   => 'global',
    );

    my @sent;
    no warnings 'redefine';
    local *Test2::Harness2::PreloadService::client = sub {
        return bless { sent => \@sent }, 'Test::PSClient';
    };
    local *Test::PSClient::send_message = sub {
        my ($self, $peer, $payload) = @_;
        push @{$self->{sent}}, [$peer, $payload];
    };

    # do_preload returns ok; we then expect a single preload_ready send.
    local *Test2::Harness2::PreloadService::_require_module = sub { 1 };

    $s->service_on_start;

    is(scalar @sent, 1, 'one message sent');
    my ($peer, $payload) = @{$sent[0]};
    is($peer, 'harness', 'sent to harness peer');
    is($payload->{kind},         'preload_ready', 'kind=preload_ready');
    is($payload->{preload_name}, 'mypl',          'preload_name carried');
    is($payload->{scope},        'global',        'scope carried');
    ok(!exists $payload->{run_id}, 'no run_id for global');
};

subtest 'service_on_start carries run_id when scope=run' => sub {
    my $s = Test2::Harness2::PreloadService->new(
        name    => 'mypl',
        modules => [],
        scope   => 'run',
        run_id  => 'RUNUUID',
    );

    my @sent;
    no warnings 'redefine';
    local *Test2::Harness2::PreloadService::client = sub {
        return bless { sent => \@sent }, 'Test::PSClient';
    };
    local *Test::PSClient::send_message = sub {
        my ($self, $peer, $payload) = @_;
        push @{$self->{sent}}, [$peer, $payload];
    };
    local *Test2::Harness2::PreloadService::_require_module = sub { 1 };

    $s->service_on_start;

    is(scalar @sent, 1, 'one message');
    my ($peer, $payload) = @{$sent[0]};
    is($payload->{scope},  'run',     'run scope');
    is($payload->{run_id}, 'RUNUUID', 'run_id present');
};

subtest 'service_on_start: do_preload failure -> no preload_ready, croak' => sub {
    my $s = Test2::Harness2::PreloadService->new(
        name    => 'mypl',
        modules => ['B::Bad'],
    );

    my @sent;
    no warnings 'redefine';
    local *Test2::Harness2::PreloadService::client = sub {
        return bless { sent => \@sent }, 'Test::PSClient';
    };
    local *Test::PSClient::send_message = sub {
        my ($self, $peer, $payload) = @_;
        push @{$self->{sent}}, [$peer, $payload];
    };
    local *Test2::Harness2::PreloadService::_require_module = sub {
        die "synthetic\n";
    };

    my $ok = eval { $s->service_on_start; 1 };
    ok(!$ok, 'service_on_start dies on do_preload failure');
    is(scalar @sent, 0, 'no preload_ready sent on failure');
};

done_testing;

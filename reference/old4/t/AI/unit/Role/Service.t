use Test2::V0;
use Time::HiRes qw/time/;

{
    package T::Service::Counted;
    use Object::HashBase qw{
        +ticks
        +work_pattern
        +stop_after
    };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init {
        my $self = shift;
        $self->{ticks}        = 0;
        $self->{work_pattern} //= [];
        $self->{stop_after}   //= 3;
    }

    sub tick {
        my $self = shift;
        $self->{ticks}++;
        my $pat = shift @{$self->{work_pattern} //= []};
        return $pat // 0;
    }

    sub should_stop {
        my $self = shift;
        return $self->{ticks} >= $self->{stop_after};
    }
}

subtest tick_drives_loop => sub {
    my $svc = T::Service::Counted->new(
        work_pattern => [1, 1, 1],
        stop_after   => 3,
    );

    my $t0 = time();
    $svc->run;
    my $elapsed = time() - $t0;

    is($svc->{ticks}, 3, 'tick called 3 times');
    ok($elapsed < 0.5, "no sleep when work returned every tick ($elapsed s)")
        or diag "elapsed: $elapsed";
};

subtest backoff_when_no_work => sub {
    my $svc = T::Service::Counted->new(
        work_pattern => [],
        stop_after   => 3,
    );

    my $t0 = time();
    $svc->run;
    my $elapsed = time() - $t0;

    is($svc->{ticks}, 3, 'tick called 3 times');
    ok($elapsed >= 0.05 + 0.1, "backoff actually slept ($elapsed s)")
        or diag "elapsed: $elapsed";
};

subtest sigusr1_wakes_sleep => sub {
    my $child = fork;
    die "fork: $!" unless defined $child;

    if ($child == 0) {
        require Time::HiRes;
        local $SIG{USR1} = sub { };
        my $t0 = Time::HiRes::time();
        Time::HiRes::sleep(2);
        my $elapsed = Time::HiRes::time() - $t0;
        exit($elapsed < 1 ? 0 : 1);
    }

    Time::HiRes::sleep(0.1);
    kill 'USR1', $child;
    waitpid($child, 0);
    is($? >> 8, 0, 'SIGUSR1 woke Time::HiRes::sleep early');
};

done_testing;

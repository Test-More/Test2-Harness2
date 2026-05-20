use Test2::V0;

use Test2::Harness2::Launcher::Default;

subtest delegate_class => sub {
    my $expected = $^O eq 'MSWin32'
        ? 'Test2::Harness2::Launcher::Win32'
        : 'Test2::Harness2::Launcher::ForkExec';
    is(Test2::Harness2::Launcher::Default->delegate_class, $expected);
};

subtest new_returns_delegate_instance => sub {
    my $obj = Test2::Harness2::Launcher::Default->new(
        handle      => undef,
        launcher_id => 1,
    );
    my $expected = $^O eq 'MSWin32'
        ? 'Test2::Harness2::Launcher::Win32'
        : 'Test2::Harness2::Launcher::ForkExec';
    isa_ok($obj, $expected);
};

done_testing;

use Test2::V0;
use Scalar::Util qw/refaddr/;

use App::Yath2::Command::help;

# Helpers ---------------------------------------------------------------

sub make_help {
    my (%extra) = @_;
    my $hs       = mock {} => (add => [verbose => sub { 0 }]);
    my $settings = mock {} => (add => [help => sub { $hs }]);
    return App::Yath2::Command::help->new(
        settings => $settings,
        args     => [],
        plugins  => [],
        %extra,
    );
}

# Override find_libraries in help's *own* symbol table for the duration
# of the calling block. find_libraries is imported (not called by FQN),
# so this is the right place to intercept it.
sub with_fake_libs (&$) {
    my ($code, $libs) = @_;
    no warnings 'redefine';
    local *App::Yath2::Command::help::find_libraries = sub { $libs };
    $code->();
}

# -----------------------------------------------------------------------
# die path: command that loads but doesn't implement the role
# -----------------------------------------------------------------------
subtest 'command_info_hash: dies for a command that lacks Role::Command' => sub {
    # Register a bare package that loads successfully but has no role.
    {
        $INC{'App/Yath2/Command/NoRoleStub.pm'} = __FILE__;
        package App::Yath2::Command::NoRoleStub;
        # deliberately no 'with App::Yath2::Role::Command'
    }

    my $help = make_help();

    with_fake_libs {
        like(
            dies { $help->command_info_hash },
            qr/App::Yath2::Command::NoRoleStub does not have a role of App::Yath2::Role::Command/,
            'command_info_hash dies when a loaded command lacks the expected role',
        );
    } {'App::Yath2::Command::NoRoleStub' => 'App/Yath2/Command/NoRoleStub.pm'};
};

# -----------------------------------------------------------------------
# happy path: command that implements the role appears in the result
# -----------------------------------------------------------------------
subtest 'command_info_hash: command with the role is included in the result' => sub {
    # help itself implements App::Yath2::Role::Command — use it as the fixture.
    my $help = make_help();

    with_fake_libs {
        my $h = $help->command_info_hash;

        ok(ref($h) eq 'HASH', 'returns a hashref');

        my @names = map { $_->[0] } map { @$_ } values %$h;
        ok(grep({ $_ eq 'help' } @names), "'help' command appears in the result");
    } {'App::Yath2::Command::help' => 'App/Yath2/Command/help.pm'};
};

# -----------------------------------------------------------------------
# tolerant path: module that fails to load goes into failed-to-load bucket
# -----------------------------------------------------------------------
subtest 'command_info_hash: failed-to-load commands are bucketed, not fatal' => sub {
    # Return a module path that does not exist; require will fail.
    my $help = make_help();

    with_fake_libs {
        my $h;
        ok(lives { $h = $help->command_info_hash }, 'does not die when a module fails to load')
            or diag $@;
        ok(exists $h->{'z  failed to load'}, 'failed commands land in the "z  failed to load" bucket');
    } {'App::Yath2::Command::Nonexistent' => 'App/Yath2/Command/Nonexistent.pm'};
};

# -----------------------------------------------------------------------
# caching: command_info_hash returns the same ref on repeated calls
# -----------------------------------------------------------------------
subtest 'command_info_hash: result is cached after the first call' => sub {
    my $help = make_help();

    with_fake_libs {
        my $h1 = $help->command_info_hash;
        my $h2 = $help->command_info_hash;
        is(refaddr($h1), refaddr($h2), 'same reference returned on second call');
    } {'App::Yath2::Command::help' => 'App/Yath2/Command/help.pm'};
};

done_testing;

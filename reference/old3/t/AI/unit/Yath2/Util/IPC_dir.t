use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();

use App::Yath2::Util::IPC qw/resolve_ipc_dir/;

# A small mock settings object that supports $settings->yath->FOO and
# $settings->ipc->FOO.
package MockGroup {
    sub new { my ($class, %v) = @_; return bless { %v } => $class; }
    sub AUTOLOAD {
        our $AUTOLOAD;
        my $m = $AUTOLOAD; $m =~ s/.*:://; return if $m eq 'DESTROY';
        return $_[0]->{$m};
    }
}
package MockSettings {
    sub new {
        my ($class, %g) = @_;
        return bless { map { $_ => MockGroup->new(%{ $g{$_} }) } keys %g } => $class;
    }
    sub AUTOLOAD {
        our $AUTOLOAD;
        my $m = $AUTOLOAD; $m =~ s/.*:://; return if $m eq 'DESTROY';
        return $_[0]->{$m};
    }
}

my $writable = tempdir(CLEANUP => 1);

# 1. CLI override wins.
{
    my $s = MockSettings->new(
        yath => { user_config_file => '', config_file => '', cwd => $writable },
        ipc  => { dir => $writable, dir_order => ['cwd', 'tempdir'] },
    );
    my ($d, $tmp) = resolve_ipc_dir($s);
    is([$d, $tmp], [$writable, F()], 'CLI --ipc-dir wins, not flagged tempdir');
}

# 2. user_rc wins over project_rc when both are present.
{
    my $user = tempdir(CLEANUP => 1);
    my $proj = tempdir(CLEANUP => 1);
    my $s = MockSettings->new(
        yath => {
            user_config_file => "$user/.yath.user.rc",
            config_file      => "$proj/.yath.rc",
            cwd              => $writable,
        },
        ipc  => { dir => undef, dir_order => ['user_rc', 'project_rc', 'cwd', 'tempdir'] },
    );
    my ($d) = resolve_ipc_dir($s);
    is($d, $user, 'user_rc precedes project_rc in default chain');
}

# 3. cwd-fallback when neither rc exists.
{
    my $s = MockSettings->new(
        yath => { user_config_file => '', config_file => '', cwd => $writable },
        ipc  => { dir => undef, dir_order => ['user_rc', 'project_rc', 'cwd', 'tempdir'] },
    );
    my ($d, $tmp) = resolve_ipc_dir($s);
    is([$d, !!$tmp], [$writable, !!0], 'cwd selected when both rc paths empty');
}

# 4. tempdir fallback flips the boolean.
{
    my $s = MockSettings->new(
        yath => { user_config_file => '', config_file => '', cwd => '/this/path/should/not/exist' },
        ipc  => { dir => undef, dir_order => ['user_rc', 'project_rc', 'cwd', 'tempdir'] },
    );
    my ($d, $tmp) = resolve_ipc_dir($s);
    ok(-d $d,                          'tempdir selected and exists');
    is($tmp, T(),                      'tempdir flag is true');
}

# 5. exhausted chain dies.
{
    my $s = MockSettings->new(
        yath => { user_config_file => '', config_file => '', cwd => '/no/such' },
        ipc  => { dir => undef, dir_order => ['user_rc', 'project_rc'] },
    );
    like(
        dies { resolve_ipc_dir($s) },
        qr/no writable IPC directory/i,
        'exhausted chain dies',
    );
}

done_testing;

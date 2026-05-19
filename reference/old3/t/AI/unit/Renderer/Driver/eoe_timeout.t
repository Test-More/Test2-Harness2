use strict;
use warnings;

use Test2::V0;
use Test2::Require::AuthorTesting;

use Time::HiRes qw/time/;

use App::Yath2::Renderer::Driver;

# F22: when the harness pid disappears AND no events arrive AND
# EOE stays false, the renderer driver should bail out after the
# grace window and return a non-zero exit code (with a diagnostic
# to STDERR).

# Stub App::Yath2::Options::Renderer::init_renderers so we don't need
# a real settings object.  The driver calls this to get the renderer
# list; returning [] means no renderers, which is fine for this test.
{
    no warnings 'redefine';
    *App::Yath2::Options::Renderer::init_renderers = sub { return [] };
}

# A fake live Log that never produces events and never flips EOE.
{
    package Stuck::Log;
    sub new      { bless {}, shift }
    sub is_live  { 1 }
    sub event    { undef }
    sub EOE      { 0 }
}

# Verify test premise: the bogus pid is truly not running.
my $bogus_pid = 999_999_999;
ok(!kill(0 => $bogus_pid), "test premise: bogus pid $bogus_pid not running");

# Capture STDERR so the diagnostic message is testable and doesn't
# clutter the test output.
my $stderr_output = '';
{
    open(my $old_stderr, '>&', \*STDERR) or die "Cannot dup STDERR: $!";
    close STDERR;
    open(STDERR, '>', \$stderr_output)   or die "Cannot redirect STDERR: $!";

    my $start = time;

    my $exit_code = App::Yath2::Renderer::Driver->run(
        log         => Stuck::Log->new,
        settings    => bless({}, 'Settings::Stub'),
        harness_pid => $bogus_pid,
        grace       => 0.5,
    );

    my $elapsed = time - $start;

    # Restore STDERR before making assertions (so failures print correctly).
    close STDERR;
    open(STDERR, '>&', $old_stderr) or die "Cannot restore STDERR: $!";

    isnt($exit_code, 0, 'non-zero exit when EOE stays false past grace window');

    ok($elapsed >= 0.5, "elapsed ${elapsed}s >= 0.5s grace window");
    ok($elapsed < 10,   "bailed out well before 10s (elapsed: ${elapsed}s)");
}

like($stderr_output, qr/EOE logic bug/i,
    'STDERR carries EOE-bug diagnostic');
like($stderr_output, qr/\Q$bogus_pid\E/,
    'STDERR mentions the disappeared harness pid');

done_testing;

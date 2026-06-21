use Test2::V0;
# HARNESS-DURATION-LONG
# HARNESS-NO-PRELOAD

# Run the inlined web-UI Playwright (JS/CSS) suite from the Perl test suite, so
# a full `prove` run also catches front-end regressions -- but ONLY where the
# Node/Playwright/browser toolchain is available, otherwise skip.
#
# Everything is bootstrapped into a TEMP dir (never the checkout's js-tests/):
# the specs + config are copied to a tempdir, `npm install` and the chromium
# download happen there. The webServer in the copied config is pointed back at
# this checkout via YATH_REPO_ROOT so `yath server` still finds lib/share/demo.
#
# Pass only when every Playwright spec passes; on failure the full Playwright output
# is dumped to STDERR. Skips (does not fail) when the toolchain is missing or
# cannot be bootstrapped (e.g. no node/npm, or no network for npm/browser).

use File::Temp qw/tempdir/;
use File::Spec;
use Cwd qw/abs_path/;
use File::Basename qw/dirname/;

my $root     = abs_path(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $js_tests = File::Spec->catdir($root, 'js-tests');

plan skip_all => "js-tests/ not found ($js_tests)" unless -d $js_tests;

# --- toolchain probe -------------------------------------------------------
sub have_cmd {
    my ($cmd) = @_;
    my $out = `$cmd --version 2>/dev/null`;
    return ($? == 0 && defined($out) && length($out)) ? 1 : 0;
}

for my $cmd (qw/node npm npx/) {
    plan skip_all => "'$cmd' not available on PATH" unless have_cmd($cmd);
}

# The Playwright webServer launches `yath server`; without the launcher there is
# no app to drive, so skip rather than fail.
my $yath_bin = $ENV{YATH_BIN} || 'yath';
plan skip_all => "'$yath_bin' launcher not found on PATH"
    unless `command -v $yath_bin 2>/dev/null` =~ /\S/;

# Run a shell command in a directory, capturing combined STDOUT+STDERR and the
# exit code. Returns ($exit, $output).
sub run_in {
    my ($dir, $cmd) = @_;
    my $q = quotemeta($dir);
    my $output = `cd $q && ( $cmd ) 2>&1`;
    return ($? >> 8, $output);
}

# --- temp workspace (auto-removed) -----------------------------------------
my $tmp = tempdir("yath-playwright-XXXXXX", TMPDIR => 1, CLEANUP => 1);

# Copy only what we need: specs + config + manifest. Never node_modules or
# generated report/result dirs from the checkout.
for my $item (qw/tests playwright.config.ts package.json package-lock.json/) {
    my $src = File::Spec->catfile($js_tests, $item);
    next unless -e $src;
    my ($e) = run_in($tmp, "cp -R " . quotemeta($src) . " .");
    die "Failed to copy $item into temp workspace" if $e;
}

plan skip_all => "no playwright.config in js-tests/"
    unless -e File::Spec->catfile($tmp, 'playwright.config.ts');

# Keep the browser download out of the checkout too. Default to the tempdir so a
# run leaves no trace; honor a caller-provided PLAYWRIGHT_BROWSERS_PATH (e.g. a
# CI cache) if one is already set.
local $ENV{PLAYWRIGHT_BROWSERS_PATH} = $ENV{PLAYWRIGHT_BROWSERS_PATH}
    // File::Spec->catdir($tmp, 'browsers');

# --- bootstrap (skip, don't fail, if it can't be done) ---------------------
{
    my ($e, $out) = run_in($tmp, "npm install --no-audit --no-fund --silent");
    if ($e) {
        diag($out);
        plan skip_all => "could not bootstrap playwright (npm install failed, exit $e)";
    }
}

{
    my ($e, $out) = run_in($tmp, "npx --no-install playwright install chromium");
    if ($e) {
        diag($out);
        plan skip_all => "could not bootstrap browser (playwright install chromium failed, exit $e)";
    }
}

# --- pick a free port for the server the config will launch ----------------
sub free_port {
    require IO::Socket::INET;
    my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
        or return 0;
    my $port = $s->sockport;
    $s->close;
    return $port;
}
my $port = free_port() || 8788;

# --- run the suite ---------------------------------------------------------
# YATH_REPO_ROOT: webServer cwd -> this checkout (so yath finds lib/share/demo).
# CI=1: never reuse a stray server on the port; launch fresh and own it.
local $ENV{YATH_REPO_ROOT}    = $root;
local $ENV{YATH_UI_TEST_PORT} = $port;
local $ENV{CI}                = 1;

my ($exit, $output) = run_in($tmp, "npx --no-install playwright test");

ok($exit == 0, "Playwright web-UI suite passed");

unless ($exit == 0) {
    print STDERR "\n==== Playwright output (exit $exit) ====\n$output\n==== end Playwright output ====\n";
    diag("Playwright suite failed (exit $exit); full output above on STDERR.");
}

done_testing;

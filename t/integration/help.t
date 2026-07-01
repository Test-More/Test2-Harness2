use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;
use App::Yath2::Util qw/find_yath/;

yath(
    command => 'help',
    args    => [],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{^Usage: .*yath COMMAND \[options\]$}m, "Found usage statement");
        like($out->{output}, qr{^Available Commands:$}m, "available commands");

        # Sample some essential commands
        like($out->{output}, qr{^\s+help:  Show the list of commands$}m,         "'help' command is listed");
        like($out->{output}, qr{^\s+test:  Run tests$}m,                         "'test' command is listed");
        like($out->{output}, qr{^\s+start:  Start the persistent test runner$}m, "'start' command is listed");
    },
);

yath(
    command => 'help',
    args    => ['help'],
    exit    => 0,
    test    => sub {
        my $out    = shift;
        my $script = find_yath();

        $out->{output} =~ s/^Detected App::Yath::Script::V# modules in local.*\n//m;

        # The help command now renders like any other command: a summary, the
        # description, a "Usage:" line, and the standard [OPTIONS] section.
        like($out->{output}, qr{^help - Show the list of commands$}m, "Found summary");
        like(
            $out->{output},
            qr{^This command provides a list of commands when called with no arguments\.}m,
            "Found description",
        );
        like(
            $out->{output},
            qr{^\QUsage: $script\E \[YATH OPTIONS\] help \[OPTIONS\]$}m,
            "Found usage line in new format",
        );
    },
);

yath(
    command => 'help',
    args    => ['test'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{^test - Run tests$}m,                      "Found summary");
        like($out->{output}, qr{^\[OPTIONS\]$}m,                           "Found single options section");
        like($out->{output}, qr{^  Developer  \(harness\)$}m,              "Found Developer category");
        like($out->{output}, qr{^  Help and Debugging  \(debug\)$}m,       "Found help category");
        like($out->{output}, qr{^  Plugins  \(harness\)$}m,                "Found plugin category");
        like($out->{output}, qr{^  Collector Options  \(collector\)$}m,    "Found collector category");
        like($out->{output}, qr{^  Display Options  \(display\)$}m,        "Found display category");
        like($out->{output}, qr{^  Finder Options  \(finder\)$}m,          "Found finder category");
        like($out->{output}, qr{^  Formatter Options  \(formatter\)$}m,    "Found formatter category");
        like($out->{output}, qr{^  JSONL Renderer Options  \(jsonl\)$}m,   "Found jsonl renderer category");
        like($out->{output}, qr{^  Run Options  \(run\)$}m,                "Found run category");
        like($out->{output}, qr{^  Runner Options  \(runner\)$}m,          "Found runner category");
        like($out->{output}, qr{^  Workspace Options  \(workspace\)$}m,    "Found workspace category");
    },
);

done_testing;

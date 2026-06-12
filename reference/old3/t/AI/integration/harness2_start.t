use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use POSIX qw/_exit/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Test2::Harness2;

my $dir = tempdir(CLEANUP => 1);

# Write a tiny test file to run.
my $test_file = "$dir/ok.t";
open my $fh, '>', $test_file or die $!;
print $fh <<'EOF';
use Test2::V0;
ok(1, "trivial pass");
done_testing;
EOF
close $fh;

# Start the service. Fork because start() takes over the process.
my $pid = fork // die $!;
if (!$pid) {
    Test2::Harness2->start(
        workdir                  => $dir,
        test_run                 => {files => [Test2::Harness2::TestFile->new(file => $test_file)]},
        finish_after_initial_run => 1,
    );
    POSIX::_exit(0);
}

waitpid $pid, 0;
my $exit = $? >> 8;
is($exit, 0, 'service exited cleanly');

ok(-e "$dir/logs/services/harness/events.jsonl.zst", 'service events log written');
ok(-e "$dir/logs/services/harness/spec.jsonl.zst",   'service spec log written');
ok(-e "$dir/logs/services/harness/report.jsonl.zst", 'service report log written');

opendir my $dh, "$dir/logs/runs" or die "Cannot open $dir/logs/runs: $!";
my @run_dirs = grep { !/^\./ && -d "$dir/logs/runs/$_" } readdir $dh;
closedir $dh;
is(scalar @run_dirs, 1, 'one run dir');

# Read the service events log and confirm key events made it through.
my $r = open_zstd_reader("$dir/logs/services/harness/events.jsonl.zst");
my @events;
while (defined(my $line = $r->readline)) {
    chomp $line;
    next unless length $line;
    push @events, decode_json($line);
}
$r->close;

my %kinds = map { ($_->{facet_data}{harness}{kind} // '') => 1 } @events;
ok($kinds{service_started}, 'service_started event present');
ok($kinds{service_stopped}, 'service_stopped event present');

done_testing;

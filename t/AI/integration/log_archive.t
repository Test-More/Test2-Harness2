use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use Time::HiRes qw/sleep time/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2;
use App::Yath2::Log;

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

my $dir = tempdir(CLEANUP => 1);

my $tf = "$dir/quick.t";
open my $fh, '>', $tf or die;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

my $spawn = Test2::Harness2->spawn(workdir => $dir, kill_timeout => 5);

$spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);

wait_until(
    sub {
        my $s = $spawn->status;
        return !@{$s->{running} // []} && !@{$s->{queue} // []};
    },
    30
) or die "run did not complete";

$spawn->finish;
$spawn->wait;

my $dir_log = App::Yath2::Log->new(dir => "$dir/logs");
isa_ok($dir_log, ['App::Yath2::Log::Directory']);

my @runs = $dir_log->runs;
is(scalar(@runs), 1, 'exactly one run on disk');
my $run_id = $runs[0];

# Sanity: harness service exists at the global scope.
ok($dir_log->has_service('harness'), 'harness service present');

# Run artifact handle is non-trivial.
my $run_a = $dir_log->artifacts($run_id);
isa_ok($run_a, ['App::Yath2::Log::Artifact']);

# Bytes of the run's spec.jsonl(.zst): non-empty.
ok(length($run_a->spec) > 0, 'run spec non-empty');

# tar.zidx round trip: archive the dir, open the file, sanity check.
my (undef, $archive) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $archive;
App::Yath2::Log->new(dir => "$dir/logs")->archive($archive);
ok(-s $archive, 'archive non-empty');

my $arc = App::Yath2::Log->new(file => $archive);
isa_ok($arc, ['App::Yath2::Log::TarZIdx']);

# Reader API is fully implemented for tar.zidx now: the listing /
# artifacts methods should report the same shape the Directory log
# reports for the same source.
is([$arc->runs], [$run_id], 'tar.zidx: same runs as Directory log');
ok($arc->has_service('harness'), 'tar.zidx: harness service present');

my $arc_run_a = $arc->artifacts($run_id);
ok(length($arc_run_a->spec) > 0, 'tar.zidx: run spec non-empty');

done_testing;

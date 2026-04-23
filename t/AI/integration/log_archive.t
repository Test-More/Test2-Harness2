use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use Time::HiRes qw/sleep/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::Loggers qw/classic_harness_loggers classic_test_loggers/;
use Test2::Harness2;
use Test2::Harness2::Util::JSON qw/decode_json_file/;
use App::Yath2::LogArchive;

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

my $spawn = Test2::Harness2->spawn(
    workdir      => $dir,
    kill_timeout => 5,
    loggers      => classic_harness_loggers($dir),
    test_loggers => classic_test_loggers(),
);

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

ok(-f "$dir/logs/artifacts.json", 'global manifest written');
my @run_manifests = glob "$dir/logs/runs/*/artifacts.json";
is(scalar(@run_manifests), 1, 'exactly one per-run manifest');

my $global = decode_json_file("$dir/logs/artifacts.json");
ok(scalar(keys %$global), 'global manifest has entries');
ok(
    (grep { m{^services/} } keys %$global),
    'global manifest has at least one services/ entry'
);

my ($run_path) = @run_manifests;
my ($run_id)   = $run_path =~ m{/runs/([^/]+)/artifacts\.json\z};
ok(defined $run_id, "extracted run_id ($run_id)");

my $run = decode_json_file($run_path);
ok(scalar(keys %$run), 'per-run manifest non-empty');

my $dir_la = App::Yath2::LogArchive->new(path => "$dir/logs");
isa_ok($dir_la, 'App::Yath2::LogArchive::Directory');

my (undef, $archive) = tempfile(OPEN => 0, SUFFIX => '.tar.bz2', UNLINK => 1);
unlink $archive;
App::Yath2::LogArchive->create(
    source => "$dir/logs",
    path   => $archive,
    format => 'tar.bz2',
);
ok(-s $archive, 'archive non-empty');

my $arc_la = App::Yath2::LogArchive->new(path => $archive);
ok(
    ref($arc_la) =~ /^App::Yath2::LogArchive::TarBz2::/,
    'opened tar.bz2 backend (' . ref($arc_la) . ')'
);

is($arc_la->artifacts,          $dir_la->artifacts,          'global artifacts round-trip');
is([$arc_la->runs],             [$dir_la->runs],             'runs round-trip');
is($arc_la->artifacts($run_id), $dir_la->artifacts($run_id), 'run artifacts round-trip');

done_testing;

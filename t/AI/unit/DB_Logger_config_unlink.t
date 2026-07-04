use Test2::V0;

# Ticket TODO-152 / finding 8: the -L logger config tempfiles were written by the
# parent File::Temp UNLINK => 0, and NOTHING removed them -- the comment claiming
# the logger "reads and unlinks" was aspirational. One ~200-byte file per -L
# target per run accumulated in TMPDIR forever.
#
# run_from_config_file must now unlink its config right after reading it (the
# child-side half of the fix; the parent keeps a teardown sweep, covered by
# Command_test_wait_for_loggers.t).

use File::Temp qw/tempdir/;
use Test2::Harness2::Util::JSON qw/encode_json/;
use App::Yath2::DB::Logger;

# A subclass whose run() is a no-op so we exercise only the config read + unlink,
# with no real connection / subscriber. run_from_config_file uses $class->new,
# so calling it through the subclass builds (and runs) the subclass.
{
    package t2h2::NoRunLogger;
    our @ISA = ('App::Yath2::DB::Logger');
    our @BUILT;
    sub run { push @BUILT, $_[0]; return 0 }
}

my $dir = tempdir(CLEANUP => 1);

subtest 'run_from_config_file removes the temp config after reading it' => sub {
    my $cfg = "$dir/yath-logger-$$-abc.json";
    open(my $fh, '>', $cfg) or die "write '$cfg': $!";
    print $fh encode_json({
        workdir => $dir,
        run_id  => 'RUN-123',
        target  => "$dir/log.sqlite",
        version => '2.000000',
    });
    close($fh);

    ok(-e $cfg, "config file exists before the logger reads it");

    my $exit = t2h2::NoRunLogger->run_from_config_file($cfg);

    is($exit, 0, "run_from_config_file returns the run() exit code");
    ok(!-e $cfg, "the temp config was unlinked after being read (no TMPDIR leak)");

    my $built = $t2h2::NoRunLogger::BUILT[-1];
    is($built->run_id, 'RUN-123', "the config values were read before the unlink");
    is($built->target, "$dir/log.sqlite", "target threaded through from the config");
};

done_testing;

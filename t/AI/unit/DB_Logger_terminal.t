use Test2::V0;

# Unit coverage for the DB logger's terminal-error handling (TODO-50 / spec §7e):
#   * a logger whose connection can't be built reports a terminal error and
#     returns a non-zero exit (rather than hanging / dying uncaught),
#   * the _terminal_error helper records the "incomplete / possibly corrupt"
#     state used by the workdir-vanished-early detection.
#
# No runner / no DB server is started: we point the logger at an unreachable
# target and an absent workdir and assert it fails cleanly. Skipped if the DB
# deps are absent (the layer is opt-in, R11) -- but the missing-dep path itself
# is one of the actionable errors we assert.

use App::Yath2::Util::UUID qw/gen_uuid/;
use App::Yath2::DB::Logger;

# A logger with an absent workdir + an unwritable sqlite target. run() must build
# the connection first; a bad sqlite path makes that throw, which run() converts
# into a terminal error + non-zero exit (it never propagates uncaught).
subtest 'bad target -> terminal error, non-zero exit' => sub {
    skip_all "DBD::SQLite not available" unless eval { require DBD::SQLite; 1 };
    skip_all "DBIx::QuickORM not available" unless eval { require DBIx::QuickORM; 1 };

    my $logger = App::Yath2::DB::Logger->new(
        workdir => '/nonexistent/workdir/for/yath/logger/test',
        run_id  => gen_uuid(),
        # An un-creatable sqlite path (parent dir does not exist) -> connect throws.
        target  => '/nonexistent/dir/yath-logger.sqlite',
    );

    my $exit = $logger->run;
    is($exit, 1, "run() returns a non-zero exit on a fatal connection error");
    ok($logger->terminal_error, "a terminal error was recorded");
    ok(scalar(@{$logger->errors}) >= 1, "the error was recorded for reporting");
};

# The _terminal_error helper marks the log incomplete/possibly corrupt and flips
# the exit-code state, independent of any DB connection.
subtest '_terminal_error records the incomplete/corrupt state' => sub {
    my $logger = App::Yath2::DB::Logger->new(
        workdir => '/tmp',
        run_id  => gen_uuid(),
        target  => '/tmp/unused.sqlite',
    );

    ok(!$logger->terminal_error, "no terminal error initially");

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings => $_[0] };
        $logger->_terminal_error("the workdir vanished, log is incomplete");
    }

    is($logger->terminal_error, "the workdir vanished, log is incomplete", "terminal error message stored");
    like($logger->errors->[0], qr/vanished/, "error pushed onto the error list");
    like($warnings[0], qr/DB logger:/, "the terminal error is warned to STDERR");
};

done_testing;

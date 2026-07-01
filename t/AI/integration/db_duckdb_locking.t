use Test2::V0;

# DuckDB single-writer lock semantics -- this is WHY DuckDB is a sync/read target
# and NOT a live logging target, and the contract the read-only serve path relies
# on. A .duckdb file permits only ONE read-write process at a time: the writer
# holds an exclusive, PROCESS-LEVEL lock for its whole life, and other processes
# can open the file only read-only and only AFTER that writer has detached.
# ($dbh->disconnect + undef does NOT release the lock for OTHER processes -- only
# the holding process EXITING does -- so the writer here lives in a forked child
# that we signal to exit.)
#
# All assertions run in the PARENT; the children only do DB work and report their
# outcome through small files (no child runs a Test2 assertion, so there is no
# Test2::IPC event culling across the fork).
#
# Proven:
#   1. while a writer child holds the file read-write, a second process opening it
#      -- even read-only -- FAILS with a lock conflict;
#   2. after the writer child exits, a read-only reader opens, sees the committed
#      rows, and CANNOT write (access_mode=read_only is enforced).

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;
eval { require DBD::DuckDB; 1 } or skip_all "DBD::DuckDB not available";

require DBI;
require File::Temp;
require POSIX;

my $tmp  = File::Temp->newdir(CLEANUP => 1);
my $path = "$tmp/lock.duckdb";
my $dsn  = "dbi:DuckDB:dbname=$path";

# The read-only attrs every reader uses: access_mode=read_only is the knob that
# both permits many concurrent readers AND forbids writes (the plain
# duckdb_read_only attr does NOT block writes). Readers must not CHECKPOINT.
my %RO_ATTRS = (
    AutoCommit                      => 1,
    RaiseError                      => 1,
    PrintError                      => 0,
    duckdb_config                   => {access_mode => 'read_only'},
    duckdb_checkpoint_on_disconnect => 0,
);

# Children report through these files (a single status line each).
my $r1_out = "$tmp/reader1.txt";
my $r2_out = "$tmp/reader2.txt";

sub _write_file {
    my ($file, $text) = @_;
    open my $fh, '>', $file or POSIX::_exit(99);
    print $fh $text;
    close $fh;
}

sub _read_file {
    my ($file) = @_;
    open my $fh, '<', $file or die "open '$file': $!";
    local $/;
    return <$fh>;
}

pipe(my $ready_r, my $ready_w) or die "pipe: $!";
pipe(my $ctrl_r,  my $ctrl_w)  or die "pipe: $!";

# ---- WRITER child: open read-write, write 2 rows, signal "ready", then hold the
# lock until the control pipe closes (EOF), then _exit -- releasing the lock. ----
my $writer = fork // die "fork: $!";
unless ($writer) {
    close $ready_r;
    close $ctrl_w;
    my $ok = eval {
        my $dbh = DBI->connect($dsn, '', '', {AutoCommit => 1, RaiseError => 1, PrintError => 0});
        $dbh->do("CREATE TABLE t (id INTEGER)");
        $dbh->do("INSERT INTO t VALUES (1)");
        $dbh->do("INSERT INTO t VALUES (2)");
        1;
    };
    syswrite($ready_w, $ok ? "1" : "0");
    close $ready_w;
    my $buf;
    sysread($ctrl_r, $buf, 1);    # blocks until the parent closes $ctrl_w (EOF)
    POSIX::_exit(0);
}

close $ready_w;
close $ctrl_r;

# Wait for the writer to confirm it holds the read-write lock.
my $sig = '';
sysread($ready_r, $sig, 1);
close $ready_r;
is($sig, '1', "writer child opened the .duckdb read-write and committed rows");

# ---- READER-1, WHILE the writer holds the lock: a read-only open MUST fail. ----
my $reader1 = fork // die "fork: $!";
unless ($reader1) {
    close $ctrl_w;
    my $ok  = eval { DBI->connect($dsn, '', '', {%RO_ATTRS}); 1 };
    my $err = $ok ? '' : $@;
    _write_file($r1_out, $ok ? "OPENED" : "FAILED: $err");
    POSIX::_exit(0);
}
waitpid($reader1, 0);

like(
    _read_file($r1_out),
    qr/^FAILED:.*(?:Conflicting lock|Could not set lock)/s,
    "a second process cannot open a writer-held .duckdb (read-only open conflicts on the lock)",
);

# ---- Release the writer: closing the control pipe EOFs its sysread, so it exits.
close $ctrl_w;
waitpid($writer, 0);
is($?, 0, "writer child exited cleanly (releasing the process-level lock)");

# ---- READER-2, AFTER the writer exited: read-only open succeeds, sees the rows,
# and cannot write. ----
my $reader2 = fork // die "fork: $!";
unless ($reader2) {
    my $result;
    my $ok = eval {
        my $dbh = DBI->connect($dsn, '', '', {%RO_ATTRS});
        my ($count) = $dbh->selectrow_array("SELECT count(*) FROM t");
        my $wrote = eval { $dbh->do("INSERT INTO t VALUES (3)"); 1 } ? 1 : 0;
        $result = "OK count=$count write_blocked=" . ($wrote ? "0" : "1");
        1;
    };
    _write_file($r2_out, $ok ? $result : "FAILED: $@");
    POSIX::_exit(0);
}
waitpid($reader2, 0);

my $r2 = _read_file($r2_out);
like($r2, qr/^OK /,                "after the writer exits, a read-only reader opens the .duckdb");
like($r2, qr/\bcount=2\b/,         "the read-only reader sees both rows the writer committed");
like($r2, qr/\bwrite_blocked=1\b/, "the read-only handle cannot write (access_mode=read_only enforced)");

done_testing;

use Test2::V0;

# Ticket #89: golden-output guard for App::Yath2::Command render_final_data in
# both TABLE and PLAIN (--no-final-table) modes. The final-data renderer was
# unified (one section spec drives both formats) and hoisted from the test
# command into the App::Yath2::Command base; this pins the exact byte output of
# both modes so the unification stays behavior-preserving. TABLE_TERM_SIZE is
# pinned so the Test2::Util::Table layout is deterministic.

$ENV{TABLE_TERM_SIZE} = 80;

BEGIN { require App::Yath2::Command::test }

{ package t2h2::FD::Display;
  sub new { my ($c,%a)=@_; bless {%a}, $c }
  sub quiet          { $_[0]->{quiet} }
  sub no_final_table { $_[0]->{no_final_table} }
  sub color          { $_[0]->{color} }
}
{ package t2h2::FD::Settings;
  sub new { my ($c,%a)=@_; bless {%a}, $c }
  sub display { $_[0]->{display} }
}
{ package t2h2::FD::Cmd;
  our @ISA = ("App::Yath2::Command::test");
  sub new { my ($c,%a)=@_; bless {%a}, $c }
  sub settings { $_[0]->{settings} }
}

# Capture everything the render prints to the default output handle.
sub capture_stdout {
    my ($code) = @_;
    my $buf = "";
    open(my $fh, ">", \$buf) or die $!;
    my $old = select($fh);
    my $ok  = eval { $code->(); 1 };
    my $err = $@;
    select($old);
    close($fh);
    die $err unless $ok;
    return $buf;
}

# Covers every section (retried/failed/halted/unseen), a failed job with no
# subtests, a failed job with a nested subtest map, and a halted job with a
# falsy reason (which plain mode omits).
my $final_data = {
    pass    => 0,
    retried => [ ["JOB-1", 3, "t/retry.t", "YES"] ],
    failed  => [
        ["JOB-2", "t/fail.t", undef],
        ["JOB-3", "t/subs.t", [ ["outer", [ ["inner", []] ]] ]],
    ],
    halted  => [
        ["JOB-4", "t/halt.t", "bail out"],
        ["JOB-5", "t/halt2.t", ""],
    ],
    unseen  => [ ["JOB-6", "t/unseen.t"] ],
};

sub render_mode {
    my ($no_final_table) = @_;
    my $cmd = t2h2::FD::Cmd->new(
        settings => t2h2::FD::Settings->new(
            display => t2h2::FD::Display->new(quiet => 0, no_final_table => $no_final_table, color => 0),
        ),
    );
    $cmd->{App::Yath2::Command::test::FINAL_DATA()} = $final_data;
    return capture_stdout(sub { $cmd->render_final_data($final_data) });
}

my $table_expect = <<GOLDEN_TABLE;

The following jobs failed at least once:
+--------+-----------+-----------+-----------------------+
| Job ID | Times Run | Test File | Succeeded Eventually? |
+--------+-----------+-----------+-----------------------+
| JOB-1  | 3         | t/retry.t | YES                   |
+--------+-----------+-----------+-----------------------+

The following jobs failed:
+--------+-----------+----------------+
| Job ID | Test File | Subtests       |
+--------+-----------+----------------+
| JOB-2  | t/fail.t  |                |
|        |           |                |
| JOB-3  | t/subs.t  | outer          |
|        |           | outer -> inner |
+--------+-----------+----------------+

The following jobs requested all testing be halted:
+--------+-----------+----------+
| Job ID | Test File | Reason   |
+--------+-----------+----------+
| JOB-4  | t/halt.t  | bail out |
| JOB-5  | t/halt2.t |          |
+--------+-----------+----------+

The following jobs never ran:
+--------+------------+
| Job ID | Test File  |
+--------+------------+
| JOB-6  | t/unseen.t |
+--------+------------+
GOLDEN_TABLE

my $plain_expect = <<GOLDEN_PLAIN;

The following jobs failed at least once:
- filename: t/retry.t
  job_id: JOB-1
  times_run: 3
  succeeded_eventually: YES

The following jobs failed:
- filename: t/fail.t
  job_id: JOB-2
- filename: t/subs.t
  job_id: JOB-3
  subtests:
  - outer
  - outer -> inner

The following jobs requested all testing be halted:
- filename: t/halt.t
  job_id: JOB-4
  reason: bail out
- filename: t/halt2.t
  job_id: JOB-5

The following jobs never ran:
- filename: t/unseen.t
  job_id: JOB-6
GOLDEN_PLAIN

is(render_mode(0), $table_expect, "table-mode final-data output matches golden");
is(render_mode(1), $plain_expect, "plain-mode final-data output matches golden");

done_testing;

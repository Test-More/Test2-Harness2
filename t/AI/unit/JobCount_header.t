use Test2::V0;
use v5.38;

use Test2::Harness2::Runner::Resource::JobCount;

# Ticket TODO-138 finding (40) / cleanup TODO-80 step 1: JobCount's status_data used the
# key 'headers', but the base renderer (Resource::status_lines) reads only
# 'header' -- so the `yath resources` slot table rendered with NO header row. The
# fix renames 'headers' -> 'header'.

subtest jobcount_status_data_header => sub {
    my $r = Test2::Harness2::Runner::Resource::JobCount->new(job_count => 4);

    my $data  = $r->status_data;
    my $table = $data->[0]{tables}[0];

    is($table->{header}, [qw/Runtime Slots Name/], "status_data uses 'header' with the expected columns");
    ok(!exists $table->{headers}, "no stale 'headers' key remains");
};

subtest jobcount_renders_header_row => sub {
    my $r = Test2::Harness2::Runner::Resource::JobCount->new(job_count => 4);

    # status_lines renders the table via Term::Table, which only emits a header
    # row when the 'header' key is present -- so this proves the rename took.
    my $out = $r->status_lines;
    like($out, qr/Runtime/, "rendered output includes the Runtime header");
    like($out, qr/Slots/,   "rendered output includes the Slots header");
    like($out, qr/Name/,    "rendered output includes the Name header");
};

done_testing;

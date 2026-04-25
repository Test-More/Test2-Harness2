use Test2::V0;
use Test2::Harness2::Util qw/render_status_data/;

# Empty arrayref returns undef/empty
{
    my $out = render_status_data([]);
    ok(!$out, "empty data returns false");
}

# Single group with only lines
{
    my $out = render_status_data([
        {
            title => 'Section One',
            lines => ['line 1', 'line 2'],
        },
    ]);

    like($out, qr/\*\*\*\* Section One \*\*\*\*/, "group title rendered");
    like($out, qr/line 1/, "first line rendered");
    like($out, qr/line 2/, "second line rendered");
}

# Group without a title
{
    my $out = render_status_data([
        {
            lines => ['no title here'],
        },
    ]);

    ok($out, "group without title still renders");
    unlike($out, qr/\*\*\*\*/, "no title markers when title is absent");
    like($out, qr/no title here/, "line still rendered");
}

# Group with a table
{
    my $out = render_status_data([
        {
            title  => 'Worker Table',
            tables => [
                {
                    title  => 'Workers',
                    header => ['Name', 'State'],
                    rows   => [
                        ['worker-1', 'idle'],
                        ['worker-2', 'busy'],
                    ],
                },
            ],
        },
    ]);

    like($out, qr/\*\*\*\* Worker Table \*\*\*\*/, "group title present");
    like($out, qr/\*\* Workers \*\*/, "table title present");
    like($out, qr/worker-1/, "row 1 data rendered");
    like($out, qr/worker-2/, "row 2 data rendered");
}

# Table with 'duration' format column
{
    my $out = render_status_data([
        {
            tables => [
                {
                    header => ['Task', 'Duration'],
                    format => [undef, 'duration'],
                    rows   => [
                        ['compile', 3.5],
                        ['link',    undef],
                    ],
                },
            ],
        },
    ]);

    like($out, qr/compile/, "task name rendered");
    # undef duration should render as '--'
    like($out, qr/--/, "undef duration rendered as '--'");
}

# Missing 'must pass in' croak when called with no args
{
    like(
        dies { render_status_data() },
        qr/must pass in a data array or undef/,
        "croak when called with no arguments"
    );
}

done_testing;

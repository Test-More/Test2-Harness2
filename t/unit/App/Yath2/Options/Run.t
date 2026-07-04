use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

use App::Yath2::Options::Run;

my $opts = App::Yath2::Options::Run->options;

# Parse argv through the Run option module and return the parsed 'run' group.
sub parse_run {
    my (@argv) = @_;
    my $state = $opts->process_args([@argv], skip_posts => 1);
    return $state->{settings}->run;
}

subtest 'fields option is defined' => sub {
    my @all = @{$opts->options};
    my ($opt) = grep { $_->field eq 'fields' } @all;

    ok($opt, "fields option exists");
    is($opt->group, 'run', "Option is in the run group");
    is($opt->field, 'fields', "Field name is fields");
};

# Ticket TODO-127: the name:details pattern used to be unanchored with a non-greedy
# details capture (m/([^:]+):([^:]+)/), so any value with a second colon -- a
# URL, a host:port -- had its details silently truncated at the first colon of
# the tail. The fix anchors and makes details greedy: m/^([^:]+):(.+)$/s.
subtest 'name:details values with embedded colons round-trip intact' => sub {
    my $r = parse_run('-f', 'build_url:https://ci.example.com/42');
    is(
        $r->fields,
        [{name => 'build_url', details => 'https://ci.example.com/42'}],
        "URL details survive the colons after the field name",
    );

    my $hp = parse_run('--fields', 'db:localhost:5432');
    is(
        $hp->fields,
        [{name => 'db', details => 'localhost:5432'}],
        "host:port details keep the second colon",
    );

    # A plain single-colon value is unchanged by the fix.
    my $plain = parse_run('-f', 'ticket:1234');
    is(
        $plain->fields,
        [{name => 'ticket', details => '1234'}],
        "simple name:details still parses",
    );
};

subtest 'JSON field specs still parse and validate' => sub {
    my $r = parse_run('-f', '{"name":"link","details":"https://x/y:z"}');
    is(
        $r->fields,
        [{name => 'link', details => 'https://x/y:z'}],
        "JSON details with colons preserved",
    );

    like(
        dies { parse_run('-f', 'no_colon_here') },
        qr/is not a valid field specification/,
        "a value with no colon is rejected",
    );
};

done_testing;

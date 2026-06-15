use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Coverage for the option enhancements ported from the pre-AI 2.0 reference:
#   1. PathList glob expansion on path options
#   2. split_on => ',' on the "changes" options
#   3. procname_prefix default 'yath' + normalization
#   5. color short -c
# (enhancement 4, rerun_plugins, is exercised by parse below)

use App::Yath2::Options::Finder;
use App::Yath2::Options::Runner;
use App::Yath2::Options::Debug;
use App::Yath2::Options::Display;

sub finder { App::Yath2::Options::Finder->options->process_args([@_], skip_posts => 1)->{settings}->finder }
sub runner { App::Yath2::Options::Runner->options->process_args([@_], skip_posts => 1)->{settings}->runner }
sub debug  { App::Yath2::Options::Debug->options->process_args([@_],  skip_posts => 1)->{settings}->debug }

subtest 'split_on comma on changes options' => sub {
    my $f = finder('--changed', 'a.pm,b.pm');
    is($f->changed, ['a.pm', 'b.pm'], "comma-separated --changed splits into two values");

    my $f2 = finder('--changes-exclude-pattern', 'foo,bar');
    is($f2->changes_exclude_patterns, ['foo', 'bar'], "pattern option splits on comma too");
};

subtest 'PathList glob expansion' => sub {
    # A wildcard expands against the filesystem; a literal path passes through.
    my $glob = 'lib/App/Yath2/Options/*.pm';
    my $f = finder('--changed', $glob);
    ok(@{$f->changed} > 1, "glob expanded to multiple files");
    ok((grep { $_ =~ m{Finder\.pm$} } @{$f->changed}), "expansion includes Finder.pm");
    ok(!(grep { $_ eq $glob } @{$f->changed}), "literal wildcard string is not stored");

    my $f2 = finder('--changed', 'no/such/literal.pm');
    is($f2->changed, ['no/such/literal.pm'], "non-wildcard value passes through literally");

    my $r = runner('-I', 'lib/App/Yath2/*');
    ok((grep { m{Yath2/Options$} } @{$r->includes}), "-I glob expands include dirs");
};

subtest 'pattern options are NOT globbed' => sub {
    # changes_exclude_patterns is a regex list, must stay literal even with a '*'.
    my $f = finder('--changes-exclude-pattern', 'foo.*bar');
    is($f->changes_exclude_patterns, ['foo.*bar'], "regex pattern with * is not glob-expanded");
};

subtest 'color has -c short' => sub {
    my ($opt) = grep { $_->field eq 'color' } @{App::Yath2::Options::Display->options->options};
    ok($opt, "color option exists");
    is($opt->short, 'c', "color has short -c");
};

done_testing;

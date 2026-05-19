use strict;
use warnings;

use Test2::V0;
use Test2::Require::AuthorTesting;

# After the unification, the archive command should:
#   - read its `format` setting from $settings->log->format (group 'log')
#     not from $settings->archive->format
#   - read a `compress` setting from $settings->log->compress
#   - keep the `run` / `exclude_run` options on the archive group
#   - parse --log-format and --no-log-compress on the CLI

use App::Yath2::Command::archive ();

# The Getopt::Yath instance for archive now includes_options from
# App::Yath2::Options::Log.  We verify the group membership of each
# option by scanning the flat options() list returned by the instance.

my $inst = App::Yath2::Command::archive->options;
my @opts  = @{$inst->options};

# Index: { group => { title => 1 } }
my %by_group;
for my $o (@opts) {
    $by_group{$o->group}{$o->title} = 1;
}

subtest 'format moved off the archive group onto the log group' => sub {
    ok(!exists $by_group{archive}{format},
        '`format` no longer in the archive group');

    ok(exists $by_group{log}{format},
        '`format` is in the log group');

    ok(exists $by_group{log}{compress},
        '`compress` is in the log group');
};

subtest 'archive group still owns run/exclude_run' => sub {
    ok(exists $by_group{archive}{run},
        '`run` stays on archive group');

    ok(exists $by_group{archive}{exclude_run},
        '`exclude_run` stays on archive group');
};

done_testing;

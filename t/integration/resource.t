use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;
use Test2::Harness2::Util::File::JSONL;

use Test2::Harness2::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j4', "-D$dir", '-R+Resource'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $log = $out->{log};

        my @events = $log->poll();

        my %pids;
        my %msgs;
        for my $event (@events) {
            my $f = $event->{facet_data};
            my $info = $f->{info} or next;
            for my $i (@$info) {
                next unless $i->{tag} eq 'INTERNAL';
                if ($i->{details} =~ m/^(\S+) - (yath-\S+)$/) {
                    $pids{$1} = $2;
                    next;
                }

                next unless $i->{details} =~ m/^(\S+) - (?:(\S+): \S+ - (\d)|(.+))$/;
                my ($pid, $action, $res_id) = ($1, ($2 || $4), $3);

                $pid = $pids{$pid} // $pid;

                if ($res_id) {
                    push @{$msgs{$pid}->{$res_id}} => $action;
                }
                else {
                    push @{$msgs{$pid}->{$_}} => $action for keys %{$msgs{$pid}};
                }
            }
        }

        # Chunk 5b: the scheduler is now an in-runner object, not a separate
        # process. The slot bookkeeping that used to be split between a
        # 'yath-nested-scheduler' process (assign / availability) and the
        # 'yath-nested-runner' process (record / release / cleanup) now all runs
        # in the one runner process, so the full, causally-ordered sequence
        # appears under 'yath-nested-runner' and there is no separate scheduler
        # process at all.
        is(
            $msgs{"yath-nested-runner"},
            {
                1 => [
                    'Assigned',
                    'Record',
                    'No Slots',
                    'Release',
                    'Assigned',
                    'Record',
                    'Release',
                    'RESOURCE CLEANUP',
                ],
                2 => [
                    'Assigned',
                    'Record',
                    'No Slots',
                    'Release',
                    'Assigned',
                    'Record',
                    'Release',
                    'RESOURCE CLEANUP',
                ],
            },
            "The in-runner scheduler assigned slots, knew when it was out, knew when more were ready, recorded/released, and cleaned up -- all in the runner process."
        );

        is(
            $msgs{'yath-nested-scheduler'},
            undef,
            "There is no separate scheduler process anymore (scheduler is in-runner)",
        );
    },
);

done_testing;

1;

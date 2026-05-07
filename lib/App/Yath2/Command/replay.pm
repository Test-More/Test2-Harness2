package App::Yath2::Command::replay;
use strict;
use warnings;

our $VERSION = '2.000012';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use Carp qw/croak/;

use App::Yath2::Log();
use App::Yath2::Renderer::Driver();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Renderer',
);

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 0 }
sub group              { 'log parsing' }
sub summary            { 'Replay events from a log archive or directory' }

sub cli_args { "[--] LOG" }

sub description {
    return <<"    EOT";
Replays the event stream recorded in a completed yath log. LOG is either a
.yath archive file or a directory that looks like \$workdir/logs (i.e. carries
runs/<id>/ subdirectories for the runs it stores).

Output is rendered through the same renderer pipeline as 'yath test', so
colors, formatting, and summary output match a live run.

Exit code is 0 when every replayed run passed, non-zero otherwise.
    EOT
}

sub run {
    my $self = shift;

    # Autoflush so each event lands on stdout as soon as it is
    # emitted. Matches the test command's behaviour.
    local $| = 1;
    STDERR->autoflush(1);

    my $args = $self->{+ARGS} // [];
    shift @$args if @$args && $args->[0] eq '--';

    my $path = shift @$args;
    unless (defined $path && length $path) {
        $path = App::Yath2::Log->find_latest($self->{+SETTINGS});
        print STDERR "yath replay: using latest archive: $path\n"
            if defined $path && length $path;
    }

    die "Usage: yath replay LOG\n"
        unless defined $path && length $path;

    die "Log source '$path' does not exist\n"
        unless -e $path;

    die "extra arguments after LOG\n" if @$args;

    my $log = App::Yath2::Log->new(auto => $path);

    my $exit = App::Yath2::Renderer::Driver->run(
        log      => $log,
        settings => $self->{+SETTINGS},
    );

    # Renderer driver returns 0 on clean termination; nonzero only when
    # the EOE-timeout safeguard fired (live mode) -- impossible in
    # sealed mode. Pass/fail comes from the per-job report.jsonl.zst
    # final state we walk after the renderer is done.
    if ($exit == 0) {
        $exit = _runs_failed($log) ? 1 : 0;
    }

    return $exit;
}

# Walk every (run, job, last-try) report.jsonl.zst and return true if
# any try did not pass. A run with no jobs is treated as a failure
# (matches the previous static-iteration behaviour).
sub _runs_failed {
    my ($log) = @_;

    my @runs = $log->runs;
    return 1 unless @runs;

    for my $rid (@runs) {
        my $any_jobs = 0;
        for my $jid ($log->jobs($rid)) {
            $any_jobs++;
            my $try = $log->last_try($rid, $jid);
            next unless defined $try;
            my $report = $log->artifacts({run_id => $rid, job_id => $jid, job_try => $try})->report_iter->last;
            return 1 unless $report && $report->{pass};
        }
        return 1 unless $any_jobs;
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

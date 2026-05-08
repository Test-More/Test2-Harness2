package App::Yath2::Command::failed;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Test2::Util::Table qw/table/;

use App::Yath2::Log();

use Role::Tiny::With;
with 'App::Yath2::Role::Command';
use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
    <log
};

use Getopt::Yath;
option_group {group => 'failed', category => 'Command Options'} => sub {
    option brief => (
        type        => 'Bool',
        default     => 0,
        description => 'Show only the files that failed, newline separated, no other output. If a file failed once but passed on a retry it will NOT be shown.',
    );
};

sub args_include_tests { 0 }

sub summary { "Show the failed tests from a log archive" }

sub group { 'log parsing' }

sub cli_args { "[--] LOG" }

sub description {
    return <<"    EOT";
Lists the test scripts that failed in a recorded yath log. LOG is either a
.yath archive file or a directory that looks like \$workdir/logs.

For each failed try the failing top-level subtests (read directly from the
try's report.jsonl.zst) are shown alongside the test file path. Per-job pass/
fail comes from each try's report.jsonl.zst final state.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    my $path = shift @$args;
    unless (defined $path && length $path) {
        $path = App::Yath2::Log->find_latest($settings);
        print STDERR "yath failed: using latest archive: $path\n"
            if defined $path && length $path;
    }

    die "You must specify a log archive or directory\n"
        unless defined $path && length $path;

    die "Log source '$path' does not exist\n" unless -e $path;
    die "extra arguments after LOG\n" if @$args;

    $self->{+LOG} = $path;

    my $log = App::Yath2::Log->new(auto => $path);

    my @runs = $log->runs;
    die "No runs found in '$path'\n" unless @runs;

    # Per-file aggregate. Each file collects every try's final state we
    # walk via the Log API.
    my %by_file;
    for my $rid (@runs) {
        for my $jid ($log->jobs($rid)) {
            for my $try ($log->tries($rid, $jid)) {
                my $arts = $log->artifacts({run_id => $rid, job_id => $jid, job_try => $try});

                my $spec = $arts->spec_iter->first // {};
                my $rel  = $spec->{relative};
                next unless defined $rel;

                my $report = $arts->report_iter->last // {};

                push @{$by_file{$rel}{ends}} => {
                    run_id   => $rid,
                    job_id   => $jid,
                    job_try  => $try,
                    pass     => $report->{pass} ? 1 : 0,
                    fail     => $report->{pass} ? 0 : 1,
                    stamp    => $report->{ended_at} // 0,
                    subtests => $report->{subtests} || [],
                };
            }
        }
    }

    my $brief = $settings->failed->brief;
    my @rows;
    for my $rel (sort keys %by_file) {
        my @ends = sort { ($a->{stamp} // 0) <=> ($b->{stamp} // 0) } @{$by_file{$rel}{ends}};

        my $any_fail = grep { $_->{fail} } @ends;
        next unless $any_fail;

        my $final     = $ends[-1];
        my $succeeded = $final->{fail} ? 0 : 1;

        if ($brief) {
            print $rel, "\n" unless $succeeded;
            next;
        }

        my $subtests = _collect_subtest_names(\@ends);

        push @rows => [
            $rel,
            scalar(@ends),
            $subtests,
            $succeeded ? 'YES' : 'NO',
        ];
    }

    return 0 if $brief;

    unless (@rows) {
        print "\nNo jobs failed!\n";
        return 0;
    }

    print "\nThe following jobs failed at least once:\n";
    print join "\n" => table(
        collapse => 1,
        header   => ['Test File', 'Times Run', 'Subtests', 'Succeeded Eventually?'],
        rows     => \@rows,
    );
    print "\n";

    return 0;
}

# Collect failing top-level subtest names across every failed try for
# a given file. Subtests come from each try's report.jsonl.zst final
# state ({ name, pass, count_pass, count_fail }).
sub _collect_subtest_names {
    my ($ends) = @_;
    my %seen;
    my @names;
    for my $end (@$ends) {
        next unless $end->{fail};
        my $st = $end->{subtests};
        next unless ref($st) eq 'ARRAY';
        for my $entry (@$st) {
            next unless ref($entry) eq 'HASH';
            next if $entry->{pass};
            my $name = $entry->{name};
            next unless defined $name && length $name;
            next if $seen{$name}++;
            push @names => $name;
        }
    }
    return join "\n" => @names;
}

1;

__END__

=head1 POD IS AUTO-GENERATED


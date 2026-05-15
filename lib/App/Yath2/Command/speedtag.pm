package App::Yath2::Command::speedtag;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Cwd qw/getcwd/;

use Test2::Harness2::Util qw/clean_path/;
use Test2::Harness2::Util::File::JSON;

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
    <max_short
    <max_medium
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

option_group {group => 'speedtag', category => 'Speedtag Options'} => sub {
    option generate_durations_file => (
        type => 'Auto',
        alt  => ['durations', 'duration'],

        description => "Write out a duration json file, if no path is provided 'duration.json' will be used. The .json extension is added automatically if omitted.",

        long_examples => ['', '=/path/to/durations.json'],

        autofill => sub { clean_path('durations.json') },

        normalize => sub {
            my $val = shift;
            $val .= '.json' unless $val =~ m/\.json$/;
            return clean_path($val);
        },
    );

    option pretty => (
        type        => 'Bool',
        description => "Generate a pretty 'durations.json' file when combined with --generate-durations-file. (sorted and multilines)",
        default     => 0,
    );
};

sub args_include_tests { 0 }

sub group { 'log parsing' }

sub summary { "Tag tests with duration (short medium long) using a recorded log archive" }

sub cli_args { "[--] LOG max_short_duration_seconds max_medium_duration_seconds" }

sub description {
    return <<"    EOT";
Reads per-job durations from a recorded yath log and rewrites the
HARNESS2: duration header on every test file according to the supplied
thresholds. LOG is either a .yath archive file or a directory that looks like
\$workdir/logs.

Per-job durations come from each try's spec.jsonl.zst (started_at) and
report.jsonl.zst (ended_at) final states.
    EOT
}

sub init {
    my $self = shift;

    $self->{+MAX_SHORT}  //= 15;
    $self->{+MAX_MEDIUM} //= 30;
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;

    shift @$args if @$args && $args->[0] eq '--';

    my $initial_dir = clean_path(getcwd());

    my $path = shift @$args;
    unless (defined $path && length $path) {
        $path = App::Yath2::Log->find_latest($settings);
        print STDERR "yath speedtag: using latest archive: $path\n"
            if defined $path && length $path;
    }
    die "You must specify a log archive or directory\n"
        unless defined $path && length $path;
    die "Log source '$path' does not exist\n" unless -e $path;
    $self->{+LOG} = $path;

    $self->{+MAX_SHORT}  = shift @$args if @$args;
    $self->{+MAX_MEDIUM} = shift @$args if @$args;

    die "max short duration must be an integer, got '$self->{+MAX_SHORT}'\n"
        unless $self->{+MAX_SHORT} && $self->{+MAX_SHORT} =~ m/^\d+$/;
    die "max medium duration must be an integer, got '$self->{+MAX_MEDIUM}'\n"
        unless $self->{+MAX_MEDIUM} && $self->{+MAX_MEDIUM} =~ m/^\d+$/;

    my $log = App::Yath2::Log->new(auto => $path);

    my @runs = $log->runs;
    die "No runs found in '$path'\n" unless @runs;

    my $durations_file = $settings->speedtag->generate_durations_file;
    my %durations;

    my %tagged;
    for my $rid (@runs) {
        for my $jid ($log->jobs($rid)) {
            my $try = $log->last_try($rid, $jid);
            next unless defined $try;

            my $arts   = $log->artifacts({run_id => $rid, job_id => $jid, job_try => $try});
            my $spec   = $arts->spec_iter->first // {};
            my $report = $arts->report_iter->last // {};

            my $file = $spec->{absolute};
            next unless defined $file;

            $file = clean_path($file);
            next if $tagged{$file}++;

            my $start = $spec->{started_at};
            my $stop  = $report->{ended_at};
            next unless defined $start && defined $stop;

            my $time = $stop - $start;
            next unless $time > 0;

            my $dur =
                  $time < $self->{+MAX_SHORT}  ? 'short'
                : $time < $self->{+MAX_MEDIUM} ? 'medium'
                :                                'long';

            my $rfh;
            unless (open($rfh, '<', $file)) {
                warn "Could not open file $file for reading\n";
                next;
            }

            my @lines;
            my $injected;
            my ($old, $new);
            for my $line (<$rfh>) {
                if ($line =~ m/^(\s*)(\#|\/\/)\s*HARNESS2:\s*duration\s+\S+\s*$/i) {
                    next if $injected++;
                    $old  = $line;
                    $line = "$1$2 HARNESS2: duration " . lc($dur) . "\n";
                    $new  = $line;
                }
                push @lines => $line;
            }
            close($rfh);

            unless ($injected) {
                my $new_line = "# HARNESS2: duration " . lc($dur) . "\n";
                my @header;
                while (@lines && $lines[0] =~ m/^(#|use\s|package\s)/) {
                    push @header => shift @lines;
                }
                unshift @lines => (@header, $new_line);

                $old = "<NO TAG FOUND>";
                $new = $new_line;
            }

            if ($durations_file) {
                my $tfile = $file;
                $tfile =~ s{^\Q$initial_dir\E/+}{};
                $durations{$tfile} = uc($dur);
            }

            if ($settings->harness->dummy) {
                print "Would tag (dummy) file $file with duration '$dur'\n";
                chomp($old);
                chomp($new);
                print "Old Header: $old\nNew Header: $new\n\n";
                next;
            }

            my $wfh;
            unless (open($wfh, '>', $file)) {
                warn "Could not open file $file for writing\n";
                next;
            }

            print $wfh @lines;
            close($wfh);

            print "Tagged '$dur': $file\n";
        }
    }

    if ($durations_file) {
        my $jfile = Test2::Harness2::Util::File::JSON->new(
            name   => $durations_file,
            pretty => $settings->speedtag->pretty,
        );
        $jfile->write(\%durations);
    }

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED


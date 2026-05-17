package App::Yath2::Command::times;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Test2::Util::Times qw/render_duration/;

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
    <fields
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

sub args_include_tests { 0 }

sub summary { "Get per-test durations from a recorded log archive" }

sub group { 'log parsing' }

sub cli_args { "[--] LOG [Field1] [Field2]" }

sub description {
    return <<"    EOT";
Reads a recorded yath log and prints per-test durations sorted from shortest
to longest. LOG is either a .yath archive file or a directory that looks like
\$workdir/logs.

Available sort fields are 'total' (numeric, the wall-clock duration of each
test) and 'file' (alphabetic). Optional Field arguments override the default
sort precedence; subsequent fields break ties from earlier ones.

Per-test durations are derived from each try's spec.jsonl.zst (started_at)
and report.jsonl.zst (ended_at) final states.
    EOT
}

my @NUMERIC = qw/total/;
my %NUMERIC = map { $_ => 1 } @NUMERIC;

my @ALPHA = qw/file/;
my %ALPHA = map { $_ => 1 } @ALPHA;

my @FIELDS = (@NUMERIC, @ALPHA);
my %FIELDS = map { $_ => 1 } @FIELDS;

sub run {
    my $self = shift;

    my $args = $self->args;

    my $path = $self->_resolve_log_path($args);
    $self->{+LOG} = $path;

    my @fields = $self->_resolve_sort_fields($args);
    $self->{+FIELDS} = \@fields;

    my $log = App::Yath2::Log->new(auto => $path);

    my @runs = $log->runs;
    die "No runs found in '$path'\n" unless @runs;

    my @jobs = $self->_collect_job_times($log, \@runs);

    my @rows;
    my $totals = {file => 'TOTAL', total => 0};

    @jobs = sort { $self->sort_compare($a, $b) } @jobs;

    for my $job (@jobs) {
        my $data = $job->{time};
        push @rows => $self->build_row({%$data, file => $job->{file}});
        $totals->{$_} += $data->{$_} for @NUMERIC;
    }

    push @rows => [map { '--' } @fields];
    push @rows => $self->build_row($totals);

    require Term::Table;
    my $table = Term::Table->new(
        header => [map { ucfirst($_) } @fields],
        rows   => \@rows,
    );

    print "$_\n" for $table->render;

    return 0;
}

# Resolve the LOG path from the head of @$args, falling back to the
# latest archive when none is supplied. Strips a leading '--' and
# validates the path exists.
sub _resolve_log_path {
    my ($self, $args) = @_;

    shift @$args if @$args && $args->[0] eq '--';

    my $path = shift @$args;
    unless (defined $path && length $path) {
        $path = App::Yath2::Log->find_latest($self->{+SETTINGS});
        print STDERR "yath times: using latest archive: $path\n"
            if defined $path && length $path;
    }
    die "You must specify a log archive or directory\n"
        unless defined $path && length $path;
    die "Log source '$path' does not exist\n" unless -e $path;

    return $path;
}

# Build the dedup'd sort-field list from the remaining positional
# arguments followed by the default @FIELDS. Dies on unknown fields.
sub _resolve_sort_fields {
    my ($self, $args) = @_;

    my %seen;
    my @fields;
    for my $field (@$args, @FIELDS) {
        $field = lc($field);
        next if $seen{$field}++;
        die "'$field' is not a valid field\n" unless $FIELDS{$field};
        push @fields => $field;
    }

    return @fields;
}

# Walk every run's jobs and produce {file, time => {total => ...}}
# records from each job's last-try spec / report pair. Jobs missing
# file, started_at, ended_at, or yielding a negative duration are
# skipped.
sub _collect_job_times {
    my ($self, $log, $runs) = @_;

    my @jobs;
    for my $rid (@$runs) {
        for my $jid ($log->jobs($rid)) {
            my $try = $log->last_try($rid, $jid);
            next unless defined $try;

            my $arts   = $log->artifacts({run_id => $rid, job_id => $jid, job_try => $try});
            my $spec   = $arts->spec_iter->first // {};
            my $report = $arts->report_iter->last // {};

            my $file = $spec->{relative} // $spec->{absolute};
            next unless defined $file;

            my $start = $spec->{started_at};
            my $stop  = $report->{ended_at};
            next unless defined $start && defined $stop;

            my $total = $stop - $start;
            next unless $total >= 0;

            push @jobs => {file => $file, time => {total => $total}};
        }
    }

    return @jobs;
}

sub build_row {
    my $self = shift;
    my ($data) = @_;

    return [map { $NUMERIC{$_} && defined($data->{$_}) ? render_duration($data->{$_}) : $data->{$_} } @{$self->{+FIELDS}}];
}

sub sort_compare {
    my $self = shift;
    my ($ja, $jb) = @_;

    my $order = $self->{+FIELDS};

    my $ta = $ja->{time};
    my $tb = $jb->{time};

    for my $field (@$order) {
        my $fa = $field eq 'file' ? $ja->{file} : $ta->{$field};
        my $fb = $field eq 'file' ? $jb->{file} : $tb->{$field};

        my $da = defined $fa;
        my $db = defined $fb;

        next unless $da || $db;
        return 1  if $da && !$db;
        return -1 if $db && !$da;

        my $delta = $ALPHA{$field} ? lc($fa) cmp lc($fb) : $fa <=> $fb;
        return $delta if $delta;
    }

    return 0;
}

1;

__END__

=head1 METHODS

=head2 _resolve_log_path

Resolve the LOG argument from the head of C<@$args> (defaulting to
the latest archive) and validate that the path exists.

=head2 _resolve_sort_fields

Build a dedup'd ordered list of sort fields from the remaining
positional arguments followed by the defaults; dies on unknown
fields.

=head2 _collect_job_times

Walk every run's last try per job and produce per-test duration
records derived from each try's spec / report final states.

=head1 POD IS AUTO-GENERATED


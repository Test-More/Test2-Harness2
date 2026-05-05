package App::Yath2::Command::inspect;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Fcntl qw/SEEK_SET/;
use File::Spec ();
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use App::Yath2::Log;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;
include_options('App::Yath2::Options::Yath');

option_group {group => 'inspect', category => 'Inspect Options'} => sub {
    option json => (
        type        => 'Bool',
        default     => 0,
        description => "Emit machine-readable JSON instead of the human summary.",
    );
};

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group { 'log parsing' }

sub summary  { "Inspect a yath log file or directory" }
sub cli_args { "[--] log_path" }

sub description {
    return <<"    EOT";
Inspect a yath log archive or extracted directory.

Detects the on-disk format (sqlite, tar.zidx, or a directory),
verifies that the harness service entry-point artifacts
(F<services/harness/spec.jsonl.zst> and
F<services/harness/events.jsonl.zst>) are present, and prints a
summary with the runs and global services it contains.

For SQLite-backed multi-archive databases, prints one line per
contained archive with its UUID and run count.

Pass --json for a machine-readable report.

Exit code is 0 on a valid log; non-zero with a stderr diagnostic
otherwise.
    EOT
}

sub args_include_tests { 0 }

sub run {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    my $args     = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    my $path = shift @$args;
    die "log_path is required\n" unless defined $path && length $path;
    die "extra arguments after log_path\n" if @$args;
    die "path '$path' does not exist\n" unless -e $path;

    my $want_json = $settings->inspect->json ? 1 : 0;

    my $report = $self->_build_report($path);

    if ($want_json) {
        print encode_json($report), "\n";
    }
    else {
        print $self->_format_human($report);
    }

    return $report->{valid} ? 0 : 1;
}

# Build a report hashref describing $path. On hard errors that prevent
# even type detection (missing magic bytes, unreadable archive) the
# report's 'valid' flag is 0 and 'error' carries the diagnostic; the
# caller stringifies it for the user.
sub _build_report {
    my ($self, $path) = @_;

    my %r = (
        path   => $path,
        type   => undef,
        valid  => 0,
    );

    if (-d $path) {
        $r{type} = 'directory';
        $self->_fill_log_report(\%r, App::Yath2::Log->new(dir => $path));
        return \%r;
    }

    my $kind = App::Yath2::Log->_detect_file_kind($path);
    if ($kind eq 'unknown') {
        $r{type}  = 'unknown';
        $r{error} = "not a yath log archive (no sqlite or tar.zidx magic)";
        return \%r;
    }

    $r{type} = $kind;

    if ($kind eq 'sqlite') {
        require App::Yath2::Log::Sqlite;
        $self->_fill_sqlite_report(\%r, $path);
        return \%r;
    }

    # tar.zidx: single archive in one file.
    my $log;
    my $ok = eval { $log = App::Yath2::Log->new(file => $path); 1 };
    unless ($ok) {
        my $err = $@;
        chomp $err;
        $r{error} = "failed to open archive: $err";
        return \%r;
    }
    $self->_fill_log_report(\%r, $log);
    return \%r;
}

# Populate $report from a single Log object (Directory / TarZIdx, or a
# Sqlite archive selected via uuid). Validates harness/spec.jsonl(.zst)
# and harness/events.jsonl(.zst) presence.
sub _fill_log_report {
    my ($self, $report, $log) = @_;

    my %h;

    my $arts;
    my $ok = eval { $arts = $log->artifacts('harness'); 1 };
    unless ($ok) {
        my $err = $@;
        chomp $err;
        $report->{error}   = "harness service entry point missing: $err";
        $report->{harness} = { ok => 0, reason => $err };
        return;
    }

    my $has_spec   = $arts->exists('spec.jsonl');
    my $has_events = $arts->exists('events.jsonl');
    my $spec_rows  = 0;
    if ($has_spec) {
        my $iter = $arts->spec_iter;
        while (defined(my $rec = $iter->next)) { $spec_rows++ }
    }

    $h{spec_present}   = $has_spec   ? 1 : 0;
    $h{events_present} = $has_events ? 1 : 0;
    $h{spec_rows}      = $spec_rows;

    my $harness_ok = ($has_spec && $has_events && $spec_rows >= 1) ? 1 : 0;
    $h{ok} = $harness_ok;

    unless ($harness_ok) {
        my @missing;
        push @missing => 'spec.jsonl(.zst)'    unless $has_spec;
        push @missing => 'events.jsonl(.zst)'  unless $has_events;
        push @missing => 'spec.jsonl has no parseable rows'
            if $has_spec && $spec_rows < 1;
        $h{reason} = join('; ', @missing);
        $report->{error} = "harness service entry point invalid: $h{reason}";
        $report->{harness} = \%h;
        return;
    }

    my @runs    = $log->runs;
    my @globals = $log->services;

    $report->{harness}     = \%h;
    $report->{runs}        = [@runs];
    $report->{run_count}   = scalar @runs;
    $report->{globals}     = [@globals];
    $report->{global_count}= scalar @globals;
    $report->{valid}       = 1;

    # Surface meta.json if present at the archive root. Live dirs
    # never have one; sealed archives (tar.zidx + DB) always do.
    my $root = $log->artifacts;
    if ($root->exists(App::Yath2::Log->META_FILENAME)) {
        my $bytes;
        my $ok = eval {
            $bytes = $root->get(App::Yath2::Log->META_FILENAME);
            1;
        };
        if ($ok) {
            my $decoded;
            my $dok = eval { $decoded = decode_json($bytes); 1 };
            $report->{meta} = $decoded if $dok;
        }
    }

    return;
}

# Fill report for a sqlite path. Lists every archive row in the DB and
# performs the harness check on each. The whole file is "valid" only
# when at least one archive is present and every archive is valid.
sub _fill_sqlite_report {
    my ($self, $report, $path) = @_;

    require App::Yath2::Log::Sqlite;
    require DBI;

    my $rows;
    my $ok = eval {
        my $dsn = "dbi:SQLite:dbname=$path";
        my $dbh = DBI->connect($dsn, undef, undef, {
            RaiseError      => 1,
            PrintError      => 0,
            AutoCommit      => 1,
            sqlite_unicode  => 1,
        });
        $rows = $dbh->selectall_arrayref(
            q{SELECT archive_uuid FROM archives ORDER BY archive_id},
            { Slice => {} },
        );
        $dbh->disconnect;
        1;
    };
    unless ($ok) {
        my $err = $@;
        chomp $err;
        $report->{error} = "could not read archive list: $err";
        return;
    }

    unless (defined $rows && @$rows) {
        $report->{error}    = "no archives in this DB";
        $report->{archives} = [];
        return;
    }

    my @archives;
    my $any_invalid = 0;
    for my $row (@$rows) {
        my $uuid = $row->{archive_uuid};
        my %a = (uuid => $uuid);

        my $log;
        my $aok = eval {
            $log = App::Yath2::Log::Sqlite->new(file => $path, uuid => $uuid);
            1;
        };
        unless ($aok) {
            my $err = $@;
            chomp $err;
            $a{valid} = 0;
            $a{error} = "could not open archive '$uuid': $err";
            $any_invalid++;
            push @archives => \%a;
            next;
        }

        my %sub = ( valid => 0 );
        $self->_fill_log_report(\%sub, $log);

        $a{valid}     = $sub{valid}     ? 1 : 0;
        $a{harness}   = $sub{harness};
        $a{runs}      = $sub{runs}      // [];
        $a{run_count} = $sub{run_count} // 0;
        $a{globals}   = $sub{globals}   // [];
        $a{global_count} = $sub{global_count} // 0;
        $a{error}     = $sub{error} if defined $sub{error};

        $any_invalid++ unless $a{valid};
        push @archives => \%a;
    }

    $report->{archives}      = \@archives;
    $report->{archive_count} = scalar @archives;
    $report->{valid}         = $any_invalid ? 0 : 1;
    $report->{error}       //= "$any_invalid archive(s) failed harness check"
        if $any_invalid;

    return;
}

sub _format_human {
    my ($self, $r) = @_;

    my $out = '';
    $out .= sprintf("Path:     %s\n", $r->{path});
    $out .= sprintf("Type:     %s\n", $r->{type} // 'unknown');

    if (!$r->{valid}) {
        $out .= "Valid:    no\n";
        $out .= sprintf("Error:    %s\n", $r->{error}) if defined $r->{error};
        return $out;
    }

    $out .= "Valid:    yes\n";

    if (($r->{type} // '') eq 'sqlite' && $r->{archives}) {
        my @arcs = @{$r->{archives}};
        $out .= sprintf("Archives: %d\n", scalar @arcs);
        for my $a (@arcs) {
            my $rc = $a->{run_count} // 0;
            my $tag = $rc == 1 ? "1 run" : "$rc runs";
            $out .= sprintf("  - %-36s  (%s)\n", $a->{uuid} // '?', $tag);
            $out .= sprintf("      INVALID: %s\n", $a->{error})
                if !$a->{valid} && defined $a->{error};
        }
        return $out;
    }

    if (my $m = $r->{meta}) {
        $out .= sprintf("Archive UUID: %s\n", $m->{archive_uuid}) if defined $m->{archive_uuid};
        $out .= sprintf("Created at:   %s\n", $m->{created_at})   if defined $m->{created_at};
        $out .= sprintf("Host:         %s\n", $m->{host})         if defined $m->{host};
        $out .= sprintf("User:         %s\n", $m->{user})         if defined $m->{user};
        $out .= sprintf("Git SHA:      %s\n", $m->{git_sha})      if defined $m->{git_sha};
        $out .= sprintf("Project:      %s\n", $m->{project})      if defined $m->{project};
        $out .= sprintf("Yath version: %s\n", $m->{yath_version}) if defined $m->{yath_version};
    }

    my $h = $r->{harness} || {};
    my $spec_rows = $h->{spec_rows} // 0;
    my $row_word  = $spec_rows == 1 ? 'row' : 'rows';
    my @parts;
    push @parts => sprintf("services/harness/spec.jsonl.zst (%d %s)", $spec_rows, $row_word)
        if $h->{spec_present};
    push @parts => "services/harness/events.jsonl.zst present"
        if $h->{events_present};
    $out .= sprintf("Harness:  %s\n", join(', ', @parts));

    my $runs = $r->{runs} || [];
    if (@$runs) {
        $out .= sprintf("Runs:     %d  (ords: %s)\n",
            scalar @$runs, join(', ', @$runs));
    }
    else {
        $out .= "Runs:     0\n";
    }

    my $globals = $r->{globals} || [];
    if (@$globals) {
        $out .= sprintf("Globals:  %d  (%s)\n",
            scalar @$globals, join(', ', @$globals));
    }
    else {
        $out .= "Globals:  0\n";
    }

    return $out;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

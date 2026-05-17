package App::Yath2::Command::inspect;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Fcntl qw/SEEK_SET/;
use File::Spec ();
use Scalar::Util qw/blessed/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use App::Yath2::Log;
use App::Yath2::Log::Footer ();

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

For sealed file-backed archives (tar.zidx and single-archive
SQLite), C<meta.json> is read directly from the YATHFOOT trailer
when present, sidestepping the archive's tar / zidx / SQLite
parser. Older archives without the trailer fall back to the
artifact-handle path.

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

    my $kind = App::Yath2::Log->detect_file_kind($path);
    if ($kind eq 'unknown') {
        $r{type}  = 'unknown';
        $r{error} = "not a yath log archive (no sqlite or tar.zidx magic)";
        return \%r;
    }

    $r{type} = $kind;

    if ($kind eq 'sqlite') {
        require App::Yath2::DB;
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

    my $arts;
    my $ok = eval { $arts = $log->artifacts('harness'); 1 };
    unless ($ok) {
        my $err = $@;
        chomp $err;
        $report->{error}   = "harness service entry point missing: $err";
        $report->{harness} = { ok => 0, reason => $err };
        return;
    }

    my $h = $self->_check_harness_entry_point($arts);

    unless ($h->{ok}) {
        $report->{error} = "harness service entry point invalid: $h->{reason}";
        $report->{harness} = $h;
        return;
    }

    my @runs    = $log->runs;
    my @globals = $log->services;

    $report->{harness}     = $h;
    $report->{runs}        = [@runs];
    $report->{run_count}   = scalar @runs;
    $report->{globals}     = [@globals];
    $report->{global_count}= scalar @globals;
    $report->{valid}       = 1;

    my $meta = $self->_load_meta($log);
    $report->{meta} = $meta if defined $meta;

    return;
}

# Inspect the harness service's spec / events artifacts and return a
# hashref describing their presence, the spec row count, and an C<ok>
# flag (plus a C<reason> when invalid).
sub _check_harness_entry_point {
    my ($self, $arts) = @_;

    my %h;
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
    }

    return \%h;
}

# Load meta.json for a log, preferring the YATHFOOT trailer on sealed
# files and falling back to the artifact-handle path. Returns the
# decoded hashref or undef when no meta can be recovered.
#
# Live dirs never have meta.json; sealed archives (tar.zidx + DB)
# always do. The trailer path extracts meta.json without touching the
# tar / zidx / SQLite parser; the artifact path serves live
# directories or older archives without a trailer.
sub _load_meta {
    my ($self, $log) = @_;

    my $meta_via_footer = $self->_read_meta_via_footer($self->_log_path($log));
    return $meta_via_footer if defined $meta_via_footer;

    my $root = $log->artifacts;
    return undef unless $root->exists(App::Yath2::Log->META_FILENAME);

    my $bytes;
    my $ok = eval {
        $bytes = $root->get(App::Yath2::Log->META_FILENAME);
        1;
    };
    return undef unless $ok;

    my $decoded;
    my $dok = eval { $decoded = decode_json($bytes); 1 };
    return $dok ? $decoded : undef;
}

# Return the on-disk path of a Log if it has one and is not live;
# undef for Directory / Live / DB-without-file backends. Used as the
# input to _read_meta_via_footer so the trailer reader sees only
# sealed file-backed archives.
sub _log_path {
    my ($self, $log) = @_;
    return undef unless defined $log;
    return undef if eval { $log->is_live } || $@;
    return $log->{path} if defined $log->{path};   # TarZIdx
    return $log->{file} if defined $log->{file};   # Sqlite (file-backed)
    return undef;
}

# Try to read meta.json from a sealed file's YATHFOOT trailer. Returns
# a decoded hashref on success, undef when the trailer is absent or
# the read fails (so the caller can fall back to the artifact API).
sub _read_meta_via_footer {
    my ($self, $path) = @_;
    return undef unless defined $path && length $path && -f $path;

    require App::Yath2::Log::Footer;
    return undef unless App::Yath2::Log::Footer::has_footer($path);

    my ($bytes, $footer);
    my $ok = eval {
        ($bytes, $footer) = App::Yath2::Log::Footer::read_meta_from_path($path);
        1;
    };
    return undef unless $ok && defined $bytes;

    my $decoded;
    my $dok = eval { $decoded = decode_json($bytes); 1 };
    return $dok ? $decoded : undef;
}

# Fill report for a sqlite path. Lists every archive row in the DB and
# performs the harness check on each. The whole file is "valid" only
# when at least one archive is present and every archive is valid.
sub _fill_sqlite_report {
    my ($self, $report, $path) = @_;

    require App::Yath2::DB;
    require App::Yath2::Log::DB;
    require DBI;

    # For single-archive sealed SQLite files, surface the file-level
    # meta.json via the YATHFOOT trailer up front so callers see it
    # at the report root without having to dig into archives[]. The
    # trailer is absent on multi-archive containers, in which case
    # the per-archive enumeration below carries the meta.
    my $meta_via_footer = $self->_read_meta_via_footer($path);
    $report->{meta} = $meta_via_footer if defined $meta_via_footer;

    my ($rows, $list_err) = $self->_list_sqlite_archives($path);
    if (defined $list_err) {
        $report->{error} = "could not read archive list: $list_err";
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
        my $a = $self->_build_sqlite_archive_entry($path, $row->{archive_uuid});
        $any_invalid++ unless $a->{valid};
        push @archives => $a;
    }

    $report->{archives}      = \@archives;
    $report->{archive_count} = scalar @archives;
    $report->{valid}         = $any_invalid ? 0 : 1;
    $report->{error}       //= "$any_invalid archive(s) failed harness check"
        if $any_invalid;

    return;
}

# Open the sqlite file, read its archive rows, and return ($rows,
# $error). On success $error is undef. On failure $rows is undef and
# $error is the chomp'd diagnostic.
sub _list_sqlite_archives {
    my ($self, $path) = @_;

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
        return (undef, $err);
    }

    return ($rows, undef);
}

# Build a single archive-entry hashref by opening the archive and
# running the standard log-report fill on it. Open failures are
# captured into the returned entry's C<error> field so the caller can
# continue with the remaining archives.
sub _build_sqlite_archive_entry {
    my ($self, $path, $uuid) = @_;

    my %a = (uuid => $uuid);

    my $log;
    my $aok = eval {
        my $db = App::Yath2::DB->new(file => $path);
        $log = App::Yath2::Log::DB->new(db => $db, uuid => $uuid);
        1;
    };
    unless ($aok) {
        my $err = $@;
        chomp $err;
        $a{valid} = 0;
        $a{error} = "could not open archive '$uuid': $err";
        return \%a;
    }

    my %sub = ( valid => 0 );
    $self->_fill_log_report(\%sub, $log);

    $a{valid}        = $sub{valid}        ? 1 : 0;
    $a{harness}      = $sub{harness};
    $a{runs}         = $sub{runs}         // [];
    $a{run_count}    = $sub{run_count}    // 0;
    $a{globals}      = $sub{globals}      // [];
    $a{global_count} = $sub{global_count} // 0;
    $a{error}        = $sub{error} if defined $sub{error};

    return \%a;
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

    $out .= $self->_format_meta_block($r->{meta}) if $r->{meta};

    if (($r->{type} // '') eq 'sqlite' && $r->{archives}) {
        my @arcs = @{$r->{archives}};
        # Single-archive sealed SQLite: meta above already covers the
        # archive uuid; skip the redundant one-line list. Multi-archive
        # containers (no footer meta) still get the full list.
        my $skip_list = (@arcs == 1 && $r->{meta});
        unless ($skip_list) {
            $out .= $self->_format_archives_list(\@arcs);
            return $out;
        }
        # Single-archive: fall through to harness/runs summary using the
        # archive's sub-report.
        my $a = $arcs[0];
        $r->{harness} //= $a->{harness};
        $r->{runs}    //= $a->{runs};
        $r->{globals} //= $a->{globals};
    }

    $out .= $self->_format_harness_summary($r);

    return $out;
}

# Render the meta.json block as a series of "Label: value" lines, one
# per defined field.
sub _format_meta_block {
    my ($self, $m) = @_;

    my $out = '';
    $out .= sprintf("Archive UUID: %s\n", $m->{archive_uuid}) if defined $m->{archive_uuid};
    $out .= sprintf("Created at:   %s\n", _format_epoch_iso($m->{created_at})) if defined $m->{created_at};
    $out .= sprintf("Host:         %s\n", $m->{host})         if defined $m->{host};
    $out .= sprintf("User:         %s\n", $m->{user})         if defined $m->{user};
    $out .= sprintf("Git SHA:      %s\n", $m->{git_sha})      if defined $m->{git_sha};
    $out .= sprintf("Project:      %s\n", $m->{project})      if defined $m->{project};
    $out .= sprintf("Yath version: %s\n", $m->{yath_version}) if defined $m->{yath_version};

    return $out;
}

# Render the multi-archive list shown for SQLite containers, with one
# line per archive (uuid + run count) and an INVALID note when the
# archive failed its harness check.
sub _format_archives_list {
    my ($self, $arcs) = @_;

    my $out = sprintf("Archives: %d\n", scalar @$arcs);
    for my $a (@$arcs) {
        my $rc  = $a->{run_count} // 0;
        my $tag = $rc == 1 ? "1 run" : "$rc runs";
        $out .= sprintf("  - %-36s  (%s)\n", $a->{uuid} // '?', $tag);
        $out .= sprintf("      INVALID: %s\n", $a->{error})
            if !$a->{valid} && defined $a->{error};
    }

    return $out;
}

# Render the Harness / Runs / Globals summary lines for a valid log
# report (or the single-archive view of a sealed SQLite container).
sub _format_harness_summary {
    my ($self, $r) = @_;

    my $h = $r->{harness} || {};
    my $spec_rows = $h->{spec_rows} // 0;
    my $row_word  = $spec_rows == 1 ? 'row' : 'rows';
    my @parts;
    push @parts => sprintf("services/harness/spec.jsonl.zst (%d %s)", $spec_rows, $row_word)
        if $h->{spec_present};
    push @parts => "services/harness/events.jsonl.zst present"
        if $h->{events_present};

    my $out = sprintf("Harness:  %s\n", join(', ', @parts));

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

# Render a hi-res unix epoch as ISO-8601 UTC for human display. Pass-
# through for any value that does not parse as a number so old archive
# data with stray strings still prints something useful.
sub _format_epoch_iso {
    my ($val) = @_;
    return $val unless defined $val;
    return $val unless $val =~ /\A-?\d+(?:\.\d+)?\z/;
    my @gm = gmtime(int $val);
    my $frac = $val - int $val;
    my $base = sprintf('%04d-%02d-%02dT%02d:%02d:%02d',
        $gm[5] + 1900, $gm[4] + 1, $gm[3], $gm[2], $gm[1], $gm[0]);
    return $base . 'Z' unless $frac;
    return sprintf('%s.%03dZ', $base, int($frac * 1000));
}

1;

__END__

=head1 METHODS

=head2 _check_harness_entry_point

Inspect the harness service's spec / events artifacts and return a
hashref describing their presence, the spec row count, and an C<ok>
flag (with a C<reason> when invalid).

=head2 _load_meta

Load C<meta.json> for a log, preferring the YATHFOOT trailer on
sealed files and falling back to the artifact-handle path.

=head2 _list_sqlite_archives

Open a SQLite log file, query its C<archives> table, and return
C<($rows, $error)> where exactly one of the two is defined.

=head2 _build_sqlite_archive_entry

Open one archive inside a SQLite container by uuid and run the
standard log-report fill on it, returning a per-archive hashref.

=head2 _format_meta_block

Render the C<meta.json> block as a series of "Label: value" lines,
one per defined field.

=head2 _format_archives_list

Render the multi-archive list shown for SQLite containers, with one
line per archive plus an INVALID note for archives that failed.

=head2 _format_harness_summary

Render the Harness / Runs / Globals summary lines from a valid log
report.

=head1 POD IS AUTO-GENERATED

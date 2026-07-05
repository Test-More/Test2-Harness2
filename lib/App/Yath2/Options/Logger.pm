package App::Yath2::Options::Logger;
use v5.38;

our $VERSION = '2.000000';

use POSIX qw/strftime/;
use File::Spec;
use Test2::Harness2::Util qw/clean_path/;

use App::Yath2::Options::Logging();    # the shared %! format expander (expand)

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Logger - the C<-L> / C<--logger> DB-logging option (spec
§7/R16, ticket TODO-50).

=head1 DESCRIPTION

Defines the B<DB logger> enable option, C<-L> / C<--logger>: B<repeatable> and
B<value-polymorphic> (spec R16). Each occurrence starts one logger process
against one database (N loggers -> N DBs):

=over 4

=item bare C<-L>

Enable DB logging at the B<default SQLite> location (a fresh sqlite file named
from C<--logger-format> in C<--logger-dir>, temp-dir fallback).

=item C<-L=path/to/db.sqlite>

A sqlite file at that path.

=item C<-L=dbi:Pg:dbname=yath;...>

Connect to another database via DSN (postgres/mariadb/...).

=back

Logging is B<opt-in> (default OFF, R11); SQLite is only the default I<target>
once enabled. The DB modules are loaded lazily by the logger, not here. C<-L> was
freed from the old jsonl logger (now a renderer, TODO-55) for exactly this (R16); the
jsonl renderer keeps long-form C<--bzip2>/C<--gzip> only.

B<DuckDB is NOT a logging target>: a C<.duckdb> file is single-writer and a live
logger does insert-then-update on referenced rows (which DuckDB forbids), so a
C<.duckdb>/C<.ddb> path or a C<dbi:DuckDB:> DSN passed to C<-L> is rejected.
DuckDB is instead a B<sync / read> target: log to sqlite or a server DB, then
C<yath db sync> / C<yath import> B<into> a C<.duckdb> file (insert-only), and
point a read-only C<yath db> / web server at the result.

=head1 PROVIDED OPTIONS

=head3 DB Logger Options

=over 4

=item -L

=item -L=path/to/db.sqlite

=item -L=$DSN

=item --logger

=item --logger=...

=item --no-logger

Enable DB logging. Repeatable; value-polymorphic (bare = default sqlite, a path =
a sqlite file, a C<dbi:...> DSN = a remote DB). Each C<-L> starts one logger. A
DuckDB target (a C<.duckdb>/C<.ddb> path or a C<dbi:DuckDB:> DSN) is B<rejected>
(DuckDB is single-writer / sync-only).

=item --logger-dir ARG

Directory for the default sqlite log file. Falls back to the system temp dir.

=item --logger-format ARG

Format for the auto-generated default sqlite log filename (POSIX::strftime + the
C<%!P>/C<%!U>/C<%!p>/C<%!S> escapes; default C<%!P%Y-%m-%d_%H:%M:%S_%!U.sqlite>).

=item --logger-lastlog

Symlink C<lastlog.sqlite> in the log dir to the default sqlite file.

=back

=cut

# A bare -L resolves to this sentinel in the list; post_process turns each
# sentinel into a freshly-named default sqlite path.
sub DEFAULT_TOKEN() { '<default>' }

option_group {group => 'logger', category => "DB Logger Options"} => sub {
    option targets => (
        type           => 'AutoList',
        name           => 'logger',
        short          => 'L',
        alt            => ['loggers'],
        long_examples  => ['', '=path/to/db.sqlite', '=$DSN'],
        short_examples => ['', '=path/to/db.sqlite', '=$DSN'],
        autofill       => sub { (DEFAULT_TOKEN()) },
        description     => 'Enable DB logging. Repeatable; value-polymorphic (bare = default sqlite, a path = a sqlite file, a dbi:... DSN = a remote DB). Each -L starts one logger. DuckDB is NOT a valid logging target (single-writer); sync/import into a .duckdb file instead.',
    );

    # Distinct primary names (--logger-dir/--logger-format/--logger-lastlog) so the
    # auto-generated --no-* negations never collide with the jsonl Logging group's
    # dir/format/lastlog options, which share this command.
    option logger_dir => (
        type        => 'Scalar',
        name        => 'logger-dir',
        normalize   => \&clean_path,
        description => 'Directory for the default log file. Falls back to the system temp dir.',
    );

    option logger_format => (
        type          => 'Scalar',
        name          => 'logger-format',
        from_env_vars => [qw/YATH_DB_LOG_FORMAT/],
        default       => '%!P%Y-%m-%d_%H:%M:%S_%!U.sqlite',
        description   => 'Format for the auto-generated default sqlite log filename (POSIX::strftime + the %!P/%!U/%!p/%!S escapes).',
    );

    option logger_lastlog => (
        type        => 'Bool',
        name        => 'logger-lastlog',
        description => 'Symlink lastlog.sqlite in the log dir to the default sqlite file.',
    );
};

# Resolve each requested logger target into a concrete target string. A bare -L
# (the DEFAULT_TOKEN sentinel) becomes a freshly-named default sqlite path under
# --logger-dir (temp-dir fallback); explicit paths/DSNs pass through unchanged.
# The resolved list is stored back on logger->targets so the spawn reads one
# truth. Logging stays OFF unless at least one -L was given (opt-in, R11).
#
# Runs at weight 102 -- after Display (100) and the jsonl group (101) so the DB
# logger never interferes with the default-formatter setup.
option_post_process 102 => sub ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->check_group('logger');
    my $logger = $settings->logger;

    my $targets = $logger->targets;
    return unless $targets && @$targets;

    my $default_path;
    my @resolved;
    for my $t (@$targets) {
        if ($t eq DEFAULT_TOKEN()) {
            $default_path //= _default_sqlite_path($logger, $settings);
            push @resolved => $default_path;
        }
        else {
            push @resolved => $t;
        }
    }

    # DuckDB is single-writer: a .duckdb file allows only one read-write process,
    # and a live logger does insert-then-update on referenced rows (which DuckDB
    # forbids). So DuckDB is NOT a valid logging target -- reject any .duckdb/.ddb
    # path or dbi:DuckDB: DSN here (the same two signals target_to_flavor uses).
    # This is a plain string check; NO DB module is loaded (core test path stays
    # DB-free, R11). DuckDB is still a SYNC/READ target: `yath db sync --to
    # x.duckdb` / `yath import --to x.duckdb` write it insert-only.
    for my $t (@resolved) {
        next unless $t =~ /\.(?:duckdb|ddb)\z/i || $t =~ /^dbi:DuckDB:/i;
        die "DuckDB ('$t') is not a valid live-logging target: a .duckdb file is "
          . "single-writer and the logger updates rows DuckDB will not let it. Log "
          . "to sqlite or a server DB, then `yath db sync`/`import` into a .duckdb file.\n";
    }

    $logger->create_option(targets => \@resolved);

    _maybe_lastlog($logger, $default_path) if $logger->logger_lastlog && defined $default_path;

    return;
};

# Build the default sqlite path the same way the jsonl renderer names its file:
# the --logger-dir (or the workspace tmp_dir / system temp), plus the
# %!-expanded format with a .sqlite extension.
sub _default_sqlite_path ($logger, $settings) {
    my $dir = $logger->logger_dir
        // ($settings->check_group('workspace') ? $settings->workspace->tmp_dir : undef)
        // File::Spec->tmpdir;

    mkdir($dir) or die "Could not create logger dir '$dir': $!"
        unless -d $dir;

    my $filename = _expand_format($logger->logger_format, $settings);

    # Force the .sqlite extension (no compression -- it is a DB; blobs are zst).
    $filename =~ s/\.(gz|bz2)$//;
    $filename =~ s/\.(sqlite|db|jsonl?)$//;
    $filename .= '.sqlite';

    return clean_path(File::Spec->catfile($dir, $filename));
}

# The same %!-expansion the jsonl naming machinery uses (project / run-id / pid /
# seconds), then strftime. Group-guarded so a missing harness/run group (e.g. a
# bare unit test of this group) degrades gracefully rather than dying.
sub _expand_format ($pattern, $settings) {
    $pattern =~ s{%!(\w)}{_expand_escape($1, $settings)}ge;
    return strftime($pattern, localtime(App::Yath2::Options::Logging::time_for_strftime()));
}

sub _expand_escape ($letter, $settings) {
    if ($letter eq 'U') {
        return $settings->check_group('run') ? $settings->run->run_id : '';
    }
    elsif ($letter eq 'p') {
        return $$;
    }
    elsif ($letter eq 'P') {
        my $project = $settings->check_group('harness') ? $settings->harness->project : undef;
        return defined($project) ? "$project~" : '';
    }
    elsif ($letter eq 'S') {
        my ($s, $m, $h) = (localtime(App::Yath2::Options::Logging::time_for_strftime()))[0, 1, 2];
        return sprintf("%05d", $s + 60 * $m + 3600 * $h);
    }
    return "%!$letter";
}

# Point lastlog.sqlite at the default sqlite file (when asked). The user asked
# for this pointer explicitly (--logger-lastlog), so a failed unlink/symlink is
# warned rather than silently swallowed (else the pointer is lost with no clue).
sub _maybe_lastlog ($logger, $path) {
    my ($vol, $dir, undef) = File::Spec->splitpath($path);
    my $link = File::Spec->catpath($vol, $dir, 'lastlog.sqlite');

    if (-l $link || -e $link) {
        unlink($link) or warn "Could not unlink '$link': $!";
    }

    # eval covers symlink-less platforms (symlink dies -> $@); a plain failure
    # (e.g. EEXIST) returns false with no die, so report $! in that case.
    unless (eval { symlink($path, $link) }) {
        warn "Could not symlink '$link' to '$path': " . ($@ || $!);
    }

    return;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

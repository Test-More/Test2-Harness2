package App::Yath2::Role::DB::Backend;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use File::Basename ();
use File::Spec ();

use Role::Tiny;

# Required methods. Implementers must provide every one.
requires qw{
    dbh flavor
    services runs jobs tries last_try
    has_service has_run has_job has_try
    artifacts event events end_of_events reset
    list_files extract archive insert
    archives archive_count has_archive scoped
};

# Default identity preprocessor. Consumers override for flavor quirks
# (e.g., App::Yath2::DB::Internal::Postgres strips COMPRESSION lz4
# when the server build lacks it).
sub preprocess_schema_sql { $_[1] }

# Per-statement skip hook. Default: never skip. Consumers override for
# flavor quirks where individual schema statements must be elided at
# bootstrap time (e.g., App::Yath2::DB::Internal::MySQL skips CREATE
# TRIGGER when the live server is MariaDB, whose dialect rejects the
# MySQL-only BIN_TO_UUID() builtin used in the trigger bodies).
sub _should_skip_schema_statement { 0 }

# Locate share/schema/$flavor.sql. Resolution order:
#   1. dev tree: walk up from __FILE__ looking for a sibling
#      share/schema/$flavor.sql (development checkout).
#   2. installed: File::ShareDir::dist_dir('Test2-Harness2')
#                 . "/schema/$flavor.sql"
sub schema_file {
    my $self = shift;
    my $flavor = $self->flavor;
    my $name   = "$flavor.sql";

    my @tried;

    my $dir = __FILE__;
    for (1 .. 10) {
        $dir = File::Basename::dirname($dir);
        my $candidate = File::Spec->catfile($dir, 'share', 'schema', $name);
        push @tried, $candidate;
        return $candidate if -e $candidate;
        last if $dir eq '/' || $dir eq '.';
    }

    my $dist_share;
    my $ok = eval {
        require File::ShareDir;
        $dist_share = File::ShareDir::dist_dir('Test2-Harness2');
        1;
    };
    if ($ok && $dist_share) {
        my $candidate = File::Spec->catfile($dist_share, 'schema', $name);
        push @tried, $candidate;
        return $candidate if -e $candidate;
    }

    croak "could not locate schema file for flavor '$flavor'; tried: "
        . join(', ', @tried);
}

# Probe for the archives table. False on any DBI error.
sub _is_bootstrapped {
    my $self = shift;
    my $ok = eval { $self->dbh->selectrow_array(q{SELECT count(*) FROM archives}); 1 };
    return $ok ? 1 : 0;
}

# Read share/schema/$flavor.sql, preprocess, split, execute. Idempotent
# (no-op when archives table already present).
sub bootstrap_schema {
    my $self = shift;
    return if $self->_is_bootstrapped;

    my $path = $self->schema_file;
    open(my $fh, '<', $path) or croak "cannot open schema file '$path': $!";
    my $sql = do { local $/; <$fh> };
    close $fh;

    $sql = $self->preprocess_schema_sql($sql);
    $sql =~ s{--[^\n]*\n}{\n}g;

    my @stmts = grep { /\S/ } split /;\s*\n/, $sql;
    for my $stmt (@stmts) {
        $stmt =~ s/^\s+//;
        $stmt =~ s/\s+$//;
        next unless length $stmt;
        next if $self->_should_skip_schema_statement($stmt);
        $self->dbh->do($stmt) or croak "schema bootstrap failed: " . $self->dbh->errstr;
    }
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::DB::Backend - the role yath DB-archive backends consume.

=head1 SYNOPSIS

    package MyBackend;
    use Role::Tiny::With;
    # ... define every required method ...
    with 'App::Yath2::Role::DB::Backend';

=head1 DESCRIPTION

The role L<App::Yath2::Log::DB> depends on. Two implementations satisfy
it: L<App::Yath2::DB::Internal> (raw SQL) and L<App::Yath2::DB::DBIC>
(DBIx::Class).

=head1 REQUIRED METHODS

=head2 Group A -- per-archive (require resolved uuid)

C<services>, C<runs>, C<jobs>, C<tries>, C<last_try>,
C<has_service>, C<has_run>, C<has_job>, C<has_try>,
C<artifacts>, C<event>, C<events>, C<end_of_events>, C<reset>,
C<list_files>, C<extract>, C<archive>, C<insert>.

=head2 Group B -- multi-archive

C<archives>, C<archive_count>, C<has_archive>, C<scoped>, C<flavor>,
C<dbh>.

=head1 PROVIDED METHODS

=over 4

=item bootstrap_schema()

Reads C<share/schema/$flavor.sql>, runs C<preprocess_schema_sql>,
splits, executes. Idempotent. DBIC's C<deploy()> is never called.

=item preprocess_schema_sql($sql)

Default identity. Consumers override for flavor quirks.

=item schema_file()

Locates C<share/schema/$flavor.sql> in the dev tree first, then the
installed share dir.

=item _is_bootstrapped()

Probes for the C<archives> table.

=back

=cut

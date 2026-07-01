package App::Yath2::Command::db::sync;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

# The DB layer is OPTIONAL (spec R11): nothing here `use`s a DB module at compile
# time. App::Yath2::DB::Connect / App::Yath2::DB::Sync are `require`d at runtime
# in run() (App::Yath2::DB::Connect throws an actionable "install ..." error when
# DBIx::QuickORM / the DBD driver is missing).

option_group {group => 'sync', category => 'DB Sync Options'} => sub {
    option from => (
        type          => 'Scalar',
        description   => 'Source database target: a sqlite file path or a "dbi:..." DSN (the -L target form).',
        long_examples => [' /path/to/run.sqlite', ' dbi:Pg:dbname=yath'],
        from_env_vars => [qw/YATH_DB_SYNC_FROM/],
    );

    option to => (
        type          => 'Scalar',
        description   => 'Destination database target: a sqlite file path or a "dbi:..." DSN (the -L target form).',
        long_examples => [' /path/to/dest.sqlite', ' dbi:Pg:dbname=yath'],
        from_env_vars => [qw/YATH_DB_SYNC_TO/],
    );

    option run_uuid => (
        type        => 'List',
        description => 'A specific run_uuid to sync (repeatable). When omitted, syncs every run present in --from but not in --to (a run_delta).',
        long_examples => [' 0190a1b2-c3d4-7e5f-8a90-b1c2d3e4f567'],
    );

    option as_user => (
        type          => 'Scalar',
        description   => 'Attribute every synced run\'s submitted_by to this user (override). Default is carry-original (find_or_create the original submitter by username on the destination).',
        from_env_vars => [qw/YATH_DB_AS_USER/],
        alt           => [qw/override-user/],
    );
};

sub name        { "db-sync" }
sub summary     { "Sync runs and associated data from one db to another" }
sub group       { "database" }

sub cli_args { "" }

sub description {
    return <<"    EOT";
Sync whole runs (a run plus all of its jobs/tries/artifacts) from one yath
database to another. Run-data UUID primary keys copy verbatim, so re-syncing a
run is an idempotent no-op; host-local natural-key foreign keys (project, host,
machine-user, submitted-by user, test_file) are remapped on the destination via
find_or_create on their natural key.

With no --run-uuid the command syncs every run present in --from but not in --to
(a run_delta). Pass one or more --run-uuid to sync a specific set instead.

submitted_by attribution defaults to carry-original; --as-user / --override-user
attributes every synced run to a single importing user.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $sync_set = $settings->sync;

    my $from = $sync_set->from or die "--from <target> is required (a sqlite path or a dbi:... DSN)\n";
    my $to   = $sync_set->to   or die "--to <target> is required (a sqlite path or a dbi:... DSN)\n";

    require App::Yath2::DB::Connect;
    require App::Yath2::Schema;    # installs qorm() + the autorow namespace
    require App::Yath2::DB::Sync;

    # --from is read-only (Sync never writes the source). Mandatory for a DuckDB
    # source (process-exclusive write lock): the source's writer must have detached.
    my ($source_con) = App::Yath2::DB::Connect::build_connection($from, read_only => 1);
    my ($dest_con)   = App::Yath2::DB::Connect::build_connection($to);

    my $sync = App::Yath2::DB::Sync->new(
        source  => $source_con,
        dest    => $dest_con,
        as_user => $sync_set->as_user,
    );

    my $run_uuids = $sync_set->run_uuid;
    my @uuids = ($run_uuids && @$run_uuids) ? @$run_uuids : $sync->run_delta;

    unless (@uuids) {
        print "\nNothing to sync: the destination already has every run from the source.\n\n";
        return 0;
    }

    print "\nSyncing " . scalar(@uuids) . " run(s) from '$from' to '$to'...\n";

    my $stats = $sync->sync_runs(\@uuids);

    printf(
        "Done. runs=%d jobs=%d job_tries=%d collectors=%d artifacts=%d (skipped %d already-present run(s)).\n\n",
        @{$stats}{qw/runs jobs job_tries collectors artifacts skipped_runs/},
    );

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::db::sync - Sync runs and associated data from one db to another.

=head1 DESCRIPTION

Implements C<yath db sync> (spec §8, ticket #53). A thin command wrapper over the
L<App::Yath2::DB::Sync> engine. See that module for the key/FK-remap/attribution
rules.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

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

package App::Yath2::Command::import;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
);

# The DB layer is OPTIONAL (spec R11): nothing here `use`s a DB module at compile
# time. App::Yath2::DB::Connect / App::Yath2::DB::Sync are `require`d at runtime
# in run().

# NOTE: the settings group is named `import_db`, NOT `import`: `import` is a
# universal method on every object (Perl's `import`), so `$settings->import`
# would dispatch to that instead of the Getopt::Yath::Settings AUTOLOAD group
# accessor. The CLI flags (--to / --as-user) come from the option names below and
# are unaffected by the group name (no prefix is set).
option_group {group => 'import_db', category => 'Import Options'} => sub {
    option to => (
        type          => 'Scalar',
        description   => 'Destination database target: a sqlite file path or a "dbi:..." DSN (the -L target form).',
        long_examples => [' /path/to/dest.sqlite', ' dbi:Pg:dbname=yath'],
        from_env_vars => [qw/YATH_DB_IMPORT_TO/],
    );

    option as_user => (
        type          => 'Scalar',
        description   => 'Attribute the imported run\'s submitted_by to this user (override). Default is carry-original (find_or_create the original submitter by username on the destination).',
        from_env_vars => [qw/YATH_DB_AS_USER/],
        alt           => [qw/override-user/],
    );
};

sub summary { "Import the single run from a sqlite log file into a database" }
sub group   { "database" }

sub cli_args { "[--] /path/to/run-log.sqlite" }

sub description {
    return <<"    EOT";
Import the SINGLE run contained in one sqlite log file into another database,
auto-selecting the only run (no run_uuid needed). A convenience wrapper over the
`yath db sync` engine for the common sqlite-log -> DB upload path.

The destination is given with --to (a sqlite path or a dbi:... DSN); the source
sqlite log file is the command argument. Run-data UUID primary keys copy
verbatim (idempotent re-import); host-local natural-key foreign keys are remapped
on the destination via find_or_create.

submitted_by attribution defaults to carry-original; --as-user / --override-user
attributes the imported run to a single importing user.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $args     = $self->args;
    my $import   = $settings->import_db;

    shift @$args if @$args && $args->[0] eq '--';

    my $source_file = shift @$args
        or die "You must specify a sqlite log file to import (the source).\n";
    die "Source log file '$source_file' does not exist.\n" unless -f $source_file;

    my $to = $import->to or die "--to <target> is required (a sqlite path or a dbi:... DSN)\n";

    require App::Yath2::DB::Sync;

    # The source is an existing log FILE/DSN (sqlite or duckdb, by extension) that
    # Sync only reads: connect_pair opens it read-only (mandatory for DuckDB, whose
    # read-write lock is process-exclusive; the source run's logger must have already
    # detached) and opens the dest as the write target. Shared with `yath db sync`.
    my ($source_con, $dest_con) = App::Yath2::DB::Sync->connect_pair($source_file, $to);

    my $sync = App::Yath2::DB::Sync->new(
        source  => $source_con,
        dest    => $dest_con,
        as_user => $import->as_user,
    );

    # The single run the log file contains (croaks on 0 or >1 runs).
    my $run_uuid = $sync->only_run_uuid;

    print "\nImporting run '$run_uuid' from '$source_file' into '$to'...\n";

    my $stats = $sync->sync_run($run_uuid);

    if ($stats->{skipped_runs}) {
        print "Run '$run_uuid' was already present in the destination; nothing to do.\n\n";
        return 0;
    }

    printf(
        "Done. runs=%d jobs=%d job_tries=%d collectors=%d artifacts=%d.\n\n",
        @{$stats}{qw/runs jobs job_tries collectors artifacts/},
    );

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::import - Import the single run from a sqlite log file into a database.

=head1 DESCRIPTION

Implements the top-level C<import> command (spec §8, ticket TODO-54). A thin
convenience wrapper over the L<App::Yath2::DB::Sync> engine that auto-selects the
single run a sqlite log file contains (no C<run_uuid> needed) and supports the
same C<submitted_by> attribution flag as C<yath db sync>.

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

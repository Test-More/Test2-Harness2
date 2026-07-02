package App::Yath2::DB::Sync;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use App::Yath2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::HashBase qw{
    <source
    <dest

    <as_user
    <override_user

    +source_flavor
    +dest_flavor

    +cache
    +stats
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::Sync - From-scratch QuickORM DB->DB run sync engine (spec §8,
ticket #53).

=head1 DESCRIPTION

Moves whole runs (a C<runs> row + all of its C<jobs> / C<job_tries> /
C<artifacts>) from one L<App::Yath2::Schema> connection to another. This is a
B<DCI> module (spec §2b): it acts on QuickORM rows, holds no algorithm fragments
in the row classes, and is reusable by both C<yath db sync> and the top-level
C<import> command.

=head2 KEYS

Run-data tables use B<UUID PKs> that are host-stable by construction
(C<run_uuid> / C<job_uuid> / C<job_try_uuid> / C<artifact_uuid>), so they
B<copy verbatim> and the whole sync is an idempotent C<upsert> keyed on the
UUID: re-syncing a run B<verifies and repairs> it (missing children are filled
in; a complete run copies nothing), and distinct runs always have distinct UUIDs
so conflicts are impossible (spec §8c).

Run-data B<FK columns that point at natural-key entities> are host-local
integers and B<MUST be remapped> (R5). Each referenced entity is resolved on the
B<destination> via C<find_or_create> on its natural key, then the FK column is
rewritten before the run-data row is written:

  runs.project_id   -> projects      (natural key: name)
  runs.host_id      -> hosts         (natural key: hostname)
  runs.ran_by       -> machine_users (natural key: host + username)
  runs.submitted_by -> users         (natural key: username)  [attribution, R7]
  jobs.test_file_id -> test_files    (natural key: project_id + filename)

The C<collectors> table (one row per events producer; test collectors carry a
job_try, service collectors carry a display_name) syncs after jobs/tries and
before artifacts -- its C<run_uuid> / C<job_try_uuid> are UUID FKs (verbatim),
and C<artifacts.collector_uuid> points at it.

=head2 ARTIFACTS

The C<data> blob is copied; C<local_path> is B<host-local> and is B<skipped>
(spec §5). Transition detail rides inside the C<events.jsonl.zst> artifact blobs,
so it syncs automatically when artifacts sync -- there is no transitions table
(R6).

=head2 submitted_by ATTRIBUTION (R7)

C<submitted_by> attribution is controlled by a flag:

=over 4

=item carry-original (default)

C<find_or_create> the original submitter by username on the destination.

=item override (C<--as-user> / C<--override-user>)

Attribute every synced run to a single importing user (the common cross-DB
case -- don't sync foreign accounts). Set the C<as_user> attribute to the
username; C<override_user> is its boolean alias.

=back

A run with a NULL C<submitted_by> stays NULL under carry-original, and is set to
the override user when overriding.

=head1 SYNOPSIS

    use App::Yath2::DB::Sync;

    my $sync = App::Yath2::DB::Sync->new(
        source  => $source_con,   # App::Yath2::Schema connection
        dest    => $dest_con,
        as_user => $username,     # optional: override submitted_by attribution
    );

    # All runs in source not already in dest (a run_delta).
    my @uuids = $sync->run_delta;

    # Sync a specific set (idempotent).
    my $stats = $sync->sync_runs(\@uuids);

    # Or the single run a sqlite log file contains (the `import` case).
    my $uuid  = $sync->only_run_uuid;

=head1 METHODS

=over 4

=cut

# The natural-key entity map (R5): table => { key => [columns], pk => col }. The
# `key` columns are the natural unique key resolved on the destination; the value
# columns are read straight off the source row.
my %NATURAL = (
    projects      => {key => ['name'],                pk => 'project_id'},
    hosts         => {key => ['hostname'],            pk => 'host_id'},
    # test_files has a composite natural key (project_id, filename); project_id is
    # itself a remapped FK, so it is resolved specially in _remap_test_file.
    test_files    => {key => ['project_id', 'filename'], pk => 'test_file_id'},
    users         => {key => ['username'],            pk => 'user_id'},
    # machine_users has a composite natural key (host, username); the host FK is
    # itself remapped (resolve the host on the dest first), so this is handled
    # specially in _remap_machine_user.
    machine_users => {key => ['host_id', 'username'], pk => 'machine_user_id'},
);

sub init ($self) {
    croak "'source' is a required attribute" unless $self->{+SOURCE};
    croak "'dest' is a required attribute"   unless $self->{+DEST};

    # override_user is an alias for as_user (the two flag spellings).
    $self->{+AS_USER} //= $self->{+OVERRIDE_USER};

    $self->{+CACHE} = {};
    $self->{+STATS} = {runs => 0, jobs => 0, job_tries => 0, collectors => 0, artifacts => 0, skipped_runs => 0};

    return;
}

# ---------------------------------------------------------------------------
# Selection.
# ---------------------------------------------------------------------------

=item @uuids = $sync->source_run_uuids

Return the lowercase C<run_uuid> of every run on the B<source> whose status is
terminal (C<complete>, C<broken>, or C<canceled>) -- in-flight runs
(C<pending> / C<running>) are not yet immutable, so they are not sync candidates.

=cut

sub source_run_uuids ($self) {
    return $self->_terminal_run_uuids($self->{+SOURCE});
}

=item @uuids = $sync->dest_run_uuids

The same, on the B<destination>.

=cut

sub dest_run_uuids ($self) {
    return $self->_terminal_run_uuids($self->{+DEST});
}

sub _terminal_run_uuids ($self, $con) {
    my @out;
    for my $run ($con->handle('runs')->all) {
        my $status = $run->field('status') // '';
        next unless $status eq 'complete' || $status eq 'broken' || $status eq 'canceled';
        push @out => lc($run->field('run_uuid'));
    }
    return @out;
}

=item @uuids = $sync->run_delta

The "runs in source not in dest" set (spec §8b): every terminal source run whose
C<run_uuid> is not already present on the destination.

=cut

sub run_delta ($self) {
    my %have = map { ($_ => 1) } $self->_all_run_uuids($self->{+DEST});
    return grep { !$have{$_} } $self->source_run_uuids;
}

# Every run_uuid on a connection, regardless of status. The any-status exclusion
# is now safe because every sync-created run lands inside a per-run destination
# transaction (#129): an interrupted sync rolls back to no trace, so a run present
# on the dest is never a sync-created partial, and the delta will re-select any run
# it does not yet hold. Legacy partials created BEFORE the #129 fix are not
# re-selected by the delta (they are already present); repair them via an explicit
# `--run-uuid`, which now always descends into the child syncs and fills the gaps.
sub _all_run_uuids ($self, $con) {
    return map { lc($_->field('run_uuid')) } $con->handle('runs')->all;
}

=item $uuid = $sync->only_run_uuid

Return the C<run_uuid> of the B<single> run the source contains, croaking if the
source holds zero or more than one run. This is the C<import> auto-select case
(spec §8 / ticket #54): a sqlite log file holds exactly one run, so no
C<run_uuid> need be supplied.

=cut

sub only_run_uuid ($self) {
    my @uuids = $self->_all_run_uuids($self->{+SOURCE});

    croak "The source database contains no runs to import"
        unless @uuids;

    croak "The source database contains " . scalar(@uuids) . " runs; "
        . "`import` auto-selects a single run. Use `yath db sync` to move a specific run_uuid."
        if @uuids > 1;

    return $uuids[0];
}

# ---------------------------------------------------------------------------
# Sync.
# ---------------------------------------------------------------------------

=item $stats = $sync->sync_runs(\@run_uuids)

Sync each listed run (and all of its jobs/tries/artifacts) from source to
destination. Idempotent: a run already present on the destination B<only skips
the runs-row insert> (counted in C<skipped_runs>); its children are always
verified/repaired via their per-UUID exists-checks, so a partially-synced run is
completed and a fully-present run copies nothing. Returns the C<stats> hashref
(counts of rows written per table, plus C<skipped_runs>).

=head2 TRANSACTIONALITY (#129)

Each per-run copy runs inside a single B<top-level destination transaction>
(C<< $dest->txn(sub {...}) >>) wrapping the whole run body -- the runs row, the
natural-key remaps, and every child sync. If the sync dies mid-run (Ctrl-C,
network drop, a constraint error on one artifact) the transaction rolls back and
the run leaves B<no trace> on the destination, so the next C<run_delta> naturally
re-selects it. The transaction is B<top-level only> and never nested: QuickORM
uses savepoints for nested transactions, which DuckDB does not support, so
C<sync_runs> must never be called from inside another QuickORM transaction. The
DuckDB dialect issues the txn via raw C<BEGIN TRANSACTION>/C<COMMIT>/C<ROLLBACK>
(working around the C<DBD::DuckDB> C<begin_work> state bug); because the sync body
is B<insert-only>, DuckDB's referenced-row-update block can never fire and a
rollback of pure inserts is plain MVCC. On rollback the in-memory C<stats>
counters are restored and the natural-key PK C<cache> is cleared (its dest PKs no
longer exist), so a reused Sync object never writes dangling FKs.

=cut

sub sync_runs ($self, $run_uuids) {
    croak "sync_runs requires an arrayref of run_uuids"
        unless ref($run_uuids) eq 'ARRAY';

    $self->_sync_one_run($_) for @$run_uuids;

    return $self->{+STATS};
}

=item $stats = $sync->sync_run($run_uuid)

Sync a single run. Convenience wrapper over C<sync_runs>.

=cut

sub sync_run ($self, $run_uuid) {
    return $self->sync_runs([$run_uuid]);
}

sub _sync_one_run ($self, $run_uuid) {
    $run_uuid = lc($run_uuid);

    my $src  = $self->{+SOURCE};
    my $dest = $self->{+DEST};

    my $src_run = $src->handle('runs', where => {run_uuid => $run_uuid})->first
        or croak "run '$run_uuid' was not found on the source database";

    # One top-level destination transaction per run: an interrupted sync leaves NO
    # trace on the dest (the runs row rolls back too), so run_delta re-selects the
    # run next time (#129). Top-level only -- nested txns use savepoints, which
    # DuckDB lacks. Insert-only body: DuckDB's referenced-row-update block cannot fire.
    my %stats_snap = %{$self->{+STATS}};
    my $ok  = eval { $dest->txn(sub { $self->_copy_run($src_run, $run_uuid) }); 1 };
    my $err = $@;
    return if $ok;

    %{$self->{+STATS}} = %stats_snap;    # rolled-back rows must not be counted
    %{$self->{+CACHE}} = ();             # rolled-back natural-key PKs are void
    die $err;
}

sub _copy_run ($self, $src_run, $run_uuid) {
    my $src  = $self->{+SOURCE};
    my $dest = $self->{+DEST};

    # Idempotency/repair (#129): a present runs row only skips the runs-row INSERT
    # (skipped_runs counts that outcome alone); the child syncs ALWAYS run -- their
    # per-UUID exists-checks make a complete run a no-op and a partial run a repair.
    if ($dest->handle('runs', where => {run_uuid => $run_uuid})->first) {
        $self->{+STATS}{skipped_runs}++;
    }
    else {
        # --- runs row: copy verbatim columns, remap the natural-key FKs (R5). ---
        my $row = $self->_row_data($src_run);

        $row->{project_id}   = $self->_remap_fk('projects', $src, $row->{project_id});
        $row->{host_id}      = $self->_remap_fk('hosts',    $src, $row->{host_id});
        $row->{ran_by}       = $self->_remap_machine_user($src, $row->{ran_by});
        $row->{submitted_by} = $self->_remap_submitted_by($src, $row->{submitted_by});

        $dest->handle('runs')->insert($row);
        $self->{+STATS}{runs}++;
    }

    # --- jobs (+ test_file remap) & their tries, then collectors, then
    # artifacts (FK order: artifacts -> collectors -> job_tries). Always descend:
    # the per-UUID exists-checks make this a no-op for a complete run and a repair
    # for a partial one (#129). ---
    $self->_sync_jobs($run_uuid);
    $self->_sync_collectors($run_uuid);
    $self->_sync_artifacts($run_uuid);

    return;
}

sub _sync_jobs ($self, $run_uuid) {
    my $src  = $self->{+SOURCE};
    my $dest = $self->{+DEST};

    for my $src_job ($src->handle('jobs', where => {run_uuid => $run_uuid})->all) {
        my $job_uuid = lc($src_job->field('job_uuid'));

        my $row = $self->_row_data($src_job);
        $row->{run_uuid}     = $run_uuid;                                          # UUID PK, verbatim
        $row->{test_file_id} = $self->_remap_test_file($src, $row->{test_file_id});    # R5 (composite key)

        unless ($dest->handle('jobs', where => {job_uuid => $job_uuid})->first) {
            $dest->handle('jobs')->insert($row);
            $self->{+STATS}{jobs}++;
        }

        $self->_sync_tries($job_uuid);
    }

    return;
}

sub _sync_tries ($self, $job_uuid) {
    my $src  = $self->{+SOURCE};
    my $dest = $self->{+DEST};

    for my $src_try ($src->handle('job_tries', where => {job_uuid => $job_uuid})->all) {
        my $try_uuid = lc($src_try->field('job_try_uuid'));
        next if $dest->handle('job_tries', where => {job_try_uuid => $try_uuid})->first;

        my $row = $self->_row_data($src_try);
        # job_try_uuid + job_uuid are UUID PKs/FKs -> verbatim (no remap).
        $dest->handle('job_tries')->insert($row);
        $self->{+STATS}{job_tries}++;
    }

    return;
}

sub _sync_collectors ($self, $run_uuid) {
    my $src  = $self->{+SOURCE};
    my $dest = $self->{+DEST};

    for my $src_col ($src->handle('collectors', where => {run_uuid => $run_uuid})->all) {
        my $collector_uuid = lc($src_col->field('collector_uuid'));
        next if $dest->handle('collectors', where => {collector_uuid => $collector_uuid})->first;

        my $row = $self->_row_data($src_col);
        # collector_uuid + run_uuid + job_try_uuid are UUID PKs/FKs -> verbatim;
        # display_name copies straight across.
        $dest->handle('collectors')->insert($row);
        $self->{+STATS}{collectors}++;
    }

    return;
}

sub _sync_artifacts ($self, $run_uuid) {
    my $src  = $self->{+SOURCE};
    my $dest = $self->{+DEST};

    for my $src_art ($src->handle('artifacts', where => {run_uuid => $run_uuid})->all) {
        my $art_uuid = lc($src_art->field('artifact_uuid'));
        next if $dest->handle('artifacts', where => {artifact_uuid => $art_uuid})->first;

        my $row = $self->_row_data($src_art);

        # run_uuid + collector_uuid are UUID PKs/FKs -> verbatim. Copy `data`,
        # SKIP `local_path` (host-local, spec §5).
        delete $row->{local_path};

        $dest->handle('artifacts')->insert($row);
        $self->{+STATS}{artifacts}++;
    }

    return;
}

# ---------------------------------------------------------------------------
# FK remap (R5).
# ---------------------------------------------------------------------------

# Resolve a single-column natural-key FK on the destination, find_or_create.
# Given the SOURCE's integer id for $table, read the source row's natural key and
# find_or_create the matching dest row, returning the DEST integer id. Cached per
# (table, source-id) so a busy run resolves each entity once.
sub _remap_fk ($self, $table, $src_con, $src_id) {
    return undef unless defined $src_id;

    my $spec = $NATURAL{$table} or croak "no natural-key spec for '$table'";

    my $cache = $self->{+CACHE}{$table} //= {};
    return $cache->{$src_id} if exists $cache->{$src_id};

    my $src_row = $src_con->handle($table, where => {$spec->{pk} => $src_id})->first
        or croak "source $table id '$src_id' not found (dangling FK)";

    my %natural = map { ($_ => $src_row->field($_)) } @{$spec->{key}};

    return $cache->{$src_id} = $self->_find_or_create($table, \%natural, $spec->{pk});
}

# test_files has a composite natural key (project_id, filename). The source row's
# project_id must itself be remapped to the dest project first, then
# find_or_create the test_file by (dest_project_id, filename).
sub _remap_test_file ($self, $src_con, $src_id) {
    return undef unless defined $src_id;

    my $cache = $self->{+CACHE}{test_files} //= {};
    return $cache->{$src_id} if exists $cache->{$src_id};

    my $src_row = $src_con->handle('test_files', where => {test_file_id => $src_id})->first
        or croak "source test_files id '$src_id' not found (dangling FK)";

    my $dest_project = $self->_remap_fk('projects', $src_con, $src_row->field('project_id'));

    return $cache->{$src_id} = $self->_find_or_create(
        'test_files',
        {project_id => $dest_project, filename => $src_row->field('filename')},
        'test_file_id',
    );
}

# machine_users has a composite natural key (host, username). The source row's
# host_id must itself be remapped to the dest host first, then find_or_create the
# machine_user by (dest_host_id, username).
sub _remap_machine_user ($self, $src_con, $src_id) {
    return undef unless defined $src_id;

    my $cache = $self->{+CACHE}{machine_users} //= {};
    return $cache->{$src_id} if exists $cache->{$src_id};

    my $src_row = $src_con->handle('machine_users', where => {machine_user_id => $src_id})->first
        or croak "source machine_users id '$src_id' not found (dangling FK)";

    my $dest_host_id = $self->_remap_fk('hosts', $src_con, $src_row->field('host_id'));

    my $natural = {host_id => $dest_host_id, username => $src_row->field('username')};

    return $cache->{$src_id} = $self->_find_or_create('machine_users', $natural, 'machine_user_id');
}

# submitted_by attribution (R7).
sub _remap_submitted_by ($self, $src_con, $src_id) {
    # Override: attribute every run to the importing user, regardless of the
    # source value (including a NULL source submitted_by).
    if (defined $self->{+AS_USER} && length $self->{+AS_USER}) {
        return $self->_find_or_create('users', {username => $self->{+AS_USER}}, 'user_id');
    }

    # Carry-original: a NULL submitter stays NULL; otherwise find_or_create the
    # original submitter by username on the dest.
    return undef unless defined $src_id;
    return $self->_remap_fk('users', $src_con, $src_id);
}

# find_or_create on a destination natural-key entity; returns the dest integer PK.
sub _find_or_create ($self, $table, $natural, $pk_col) {
    my $dest = $self->{+DEST};

    my $row = $dest->handle($table, where => $natural)->first;
    return $row->field($pk_col) if $row;

    my $new = $dest->handle($table)->insert($natural);
    return $new->field($pk_col);
}

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# Per-table BOOLEAN columns. A native-boolean source (DuckDB / PostgreSQL) returns
# FALSE as '' (empty string), which violates the 0/1 CHECK on a sqlite/mysql/percona
# dest; we normalize every boolean to 0/1/undef below so it re-deflates portably on
# ANY dest. IMPORTANT: runs.passed/failed are INTEGER counters, NOT booleans -- only
# the columns listed here are coerced (the rest copy verbatim).
my %BOOLEAN_COLUMNS = (
    runs      => {map { $_ => 1 } qw/canon pinned has_coverage has_resources/},
    jobs      => {map { $_ => 1 } qw/passed failed/},
    job_tries => {map { $_ => 1 } qw/result/},
);

# Extract a portable column hash from a QuickORM row: the INFLATED field values
# (canonical UUID strings, DateTime objects, decoded JSON refs) so the dest
# re-deflates them through its own per-engine autotypes. STORED GENERATED columns
# (the *_uuid_string mirrors, spec §3b) are maintained by the DB and MUST NOT be
# written, so they are filtered out via the source's generated-column flag.
# Boolean columns are normalized to 0/1/undef (a native-boolean source returns
# FALSE as '', which would fail a 0/1-CHECK dest; the coercion is idempotent for
# an already-0/1 source).
#
# Note: $row->fields only returns already-loaded columns (it does not force a
# fetch), so we enumerate the source's columns and read each via field(), which
# lazily fetches + inflates on demand.
sub _row_data ($self, $row) {
    my $source = $row->source;
    my $bool   = $BOOLEAN_COLUMNS{$source->name} // {};

    my %data;
    for my $name ($source->column_names) {
        next if $source->field_is_generated($name);
        my $val = $row->field($name);
        $val = $val ? 1 : 0 if $bool->{$name} && defined $val;
        $data{$name} = $val;
    }

    return \%data;
}

=item $stats = $sync->stats

The per-table write counts accumulated by C<sync_runs> (also returned from it).

=back

=cut

sub stats ($self) { return $self->{+STATS} }

1;

__END__

=pod

=head1 SEE ALSO

=over 4

=item L<App::Yath2::Command::db::sync>

The C<yath db sync> command (DB->DB, a run_uuid list or a run_delta).

=item L<App::Yath2::Command::import>

The top-level C<import> command (single-run auto-select from a sqlite log).

=item L<App::Yath2::DB::Connect>

Builds the source/dest QuickORM connections from a C<-L>-style target.

=back

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

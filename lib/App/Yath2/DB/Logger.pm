package App::Yath2::DB::Logger;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <run_id
    <target
    <version

    +con
    +flavor
    +subscriber

    +run_row_seeded
    +ran_by_id
    +project_id
    +host_id
    +artifacts_done
    +job_try_seen
    +errors
    +terminal_error
    +finished
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::Logger - The standalone DB logger process (spec §7, ticket #50).

=head1 DESCRIPTION

An independent App-side process, one per C<-L> target (N loggers -> N DBs). It
owns its own run-scoped L<Test2::Harness2::Runner::Subscriber> to the runner's
C<runner.socket> and mirrors the runner's canonical state via the
L<Test2::Harness2::Runner::Monitor> fold. From that B<folded state> -- there is
B<no transitions table> (R6) -- it upserts the C<runs> / C<jobs> / C<job_tries>
summary rows, and as each collector finalizes it stores that collector's
C<events.jsonl.zst> B<whole> as an C<artifacts> blob (with embedded binary facets
extracted into their own binary artifact rows; spec §5).

All DB code lives under C<App::Yath2>; the backend stays DB-free (spec §2c). The
DB modules are loaded B<lazily> (via L<App::Yath2::DB::Connect>) with an
actionable "install X" error, and nothing on the always-loaded command path
C<use>s a DB module at compile time (R11).

=head2 LIFECYCLE

  start harness -> start logger -> queue run        (spec §6d: attach early)

The logger subscribes (its run-scoped snapshot seeds initial state), then loops
C<poll()> upserting rows + importing finalized blobs, and exits on the run's
announced end (C<run_done>) or a socket close. While subscribed it is one of the
run's subscribers, so the runner defers its workdir cleanup until the logger
disconnects (#51). If the workdir vanishes before the import completes (runner
crash / force-kill) the logger reports a B<terminal error> and marks the log
B<incomplete and possibly corrupt> (spec §7e).

=head1 ENTRY POINTS

=over 4

=item App::Yath2::DB::Logger->run_from_config_file($path)

The forked process entry point: read the temp-JSON config
(C<{workdir, run_id, target, version}>), build a logger, run it, and return an
exit code (0 = clean, non-zero = a terminal error was reported). Used by the
C<test>/C<run> spawn.

=item $logger->run

Subscribe + drive the poll loop to completion. Returns an exit code.

=back

=cut

# The events-artifact derivation offset (spec §3.1/R2): events blob = offset 0,
# extracted binaries = offsets 1, 2, ... in stream order.
sub EVENTS_OFFSET() { 0 }

# Poll cadence + how long to keep polling after the run is announced done, to
# catch trailing finalize transitions + flush the last blobs.
sub POLL_DELAY()      { 0.02 }
sub DRAIN_TIMEOUT()   { 30 }

sub init ($self) {
    croak "'workdir' is a required attribute" unless defined $self->{+WORKDIR};
    croak "'run_id' is a required attribute"  unless defined $self->{+RUN_ID};
    croak "'target' is a required attribute"  unless defined $self->{+TARGET};

    $self->{+ARTIFACTS_DONE} = {};
    $self->{+JOB_TRY_SEEN}   = {};
    $self->{+ERRORS}         = [];

    return;
}

sub run_from_config_file ($class, $path) {
    open(my $fh, '<', $path) or die "Could not open logger config '$path': $!";
    my $json = do { local $/; <$fh> };
    close($fh);
    my $config = decode_json($json);

    my $self = $class->new(
        workdir => $config->{workdir},
        run_id  => $config->{run_id},
        target  => $config->{target},
        version => $config->{version},
    );

    return $self->run;
}

# ---------------------------------------------------------------------------
# Connection (lazy DB deps).
# ---------------------------------------------------------------------------
sub con ($self) {
    return $self->{+CON} if $self->{+CON};

    require App::Yath2::DB::Connect;
    require App::Yath2::Schema;    # installs qorm() + the autorow namespace

    my ($con, $flavor) = App::Yath2::DB::Connect::build_connection($self->{+TARGET});
    $self->{+FLAVOR} = $flavor;
    return $self->{+CON} = $con;
}

sub flavor ($self) { $self->con; return $self->{+FLAVOR} }

# ---------------------------------------------------------------------------
# Subscriber.
# ---------------------------------------------------------------------------
sub subscriber ($self) {
    return $self->{+SUBSCRIBER} if $self->{+SUBSCRIBER};

    require App::Yath2::Client;
    my $client = App::Yath2::Client->new(workdir => $self->{+WORKDIR});
    # drain_gate: ask the persistent runner to defer workdir cleanup until we
    # disconnect (after importing the run's events.jsonl.zst blobs, db spec §7e).
    my $sub    = $client->connect_subscriber(run_id => $self->{+RUN_ID}, drain_gate => 1);

    croak "DB logger could not subscribe to the runner socket"
        unless $sub;

    return $self->{+SUBSCRIBER} = $sub;
}

sub monitor ($self) { return $self->subscriber->monitor }

# ---------------------------------------------------------------------------
# The poll loop.
# ---------------------------------------------------------------------------
sub run ($self) {
    my $ok = eval { $self->_run; 1 };
    my $err = $@;

    unless ($ok) {
        $self->_terminal_error("DB logger aborted: $err");
    }

    return $self->{+TERMINAL_ERROR} ? 1 : 0;
}

sub _run ($self) {
    # Build the connection first so a missing DB dep fails BEFORE we subscribe
    # (and thus before we hold the runner's cleanup open).
    $self->con;

    my $sub = $self->subscriber;

    # Seed initial state from the subscribe snapshot, then keep folding.
    $self->_sync;

    my $drain_started;
    while (1) {
        # Workdir-vanished-early detection (spec §7e): the runner crashed / was
        # force-killed and removed the workdir before we finished. Mark the log
        # incomplete + possibly corrupt and stop.
        unless (-d $self->{+WORKDIR}) {
            $self->_terminal_error(
                "The runner workdir '$self->{+WORKDIR}' vanished before the DB logger finished; "
                . "the log is INCOMPLETE and POSSIBLY CORRUPT."
            );
            last;
        }

        $sub->poll;
        $self->_sync;

        if ($sub->closed) {
            # Socket EOF: the (transient) runner shut down. Do a final drain pass.
            $self->_sync;
            last;
        }

        if ($sub->run_done || $self->monitor->run_done($self->{+RUN_ID})) {
            # The run is announced complete. Keep draining briefly for trailing
            # finalize transitions + their blobs, then stop.
            $drain_started //= time;
            $self->_sync;
            last if $self->_all_finalized_imported;
            last if (time - $drain_started) > DRAIN_TIMEOUT;
        }

        sleep POLL_DELAY;
    }

    $self->_finalize_run_row;

    return;
}

# Have all collectors the monitor knows about reached 'finalized' AND had their
# blob imported? Used to end the drain early once everything is captured.
sub _all_finalized_imported ($self) {
    my $mon = $self->monitor;
    for my $uuid ($mon->collectors) {
        my $status = $mon->status($uuid) // '';
        return 0 unless $status eq 'finalized';
        return 0 unless $self->{+ARTIFACTS_DONE}{$uuid};
    }
    return 1;
}

# ---------------------------------------------------------------------------
# Fold the Monitor's state into rows (run / job / job_try / collector) + import
# finalized collectors' blobs.
# ---------------------------------------------------------------------------
sub _sync ($self) {
    my $mon = $self->monitor;

    $self->_ensure_run_row($mon);
    $self->_upsert_jobs($mon);
    $self->_upsert_tries($mon);
    $self->_upsert_collectors($mon);
    $self->_import_finalized($mon);

    return;
}

# Natural-key entities + the run row. Seeded once; the run row's counters/status
# are refreshed on _finalize_run_row.
sub _ensure_run_row ($self, $mon) {
    return if $self->{+RUN_ROW_SEEDED};

    my $con = $self->con;

    require Sys::Hostname;
    my $hostname = eval { Sys::Hostname::hostname() } // 'localhost';
    my $username = $self->_os_username;

    my $host  = $self->_find_or_create('hosts',    {hostname => $hostname}, 'host_id');
    my $muser = $self->_find_or_create('machine_users', {host_id => $host, username => $username}, 'machine_user_id');

    # Project name: best-effort from the workdir basename (the DB-free backend
    # does not hand us a project; the future webapp spec refines attribution).
    my $project_name = $self->_project_name;
    my $project = $self->_find_or_create('projects', {name => $project_name}, 'project_id');

    $self->{+HOST_ID}    = $host;
    $self->{+RAN_BY_ID}  = $muser;
    $self->{+PROJECT_ID} = $project;

    my $run_uuid = lc($self->{+RUN_ID});

    # Idempotent: a re-run of the logger (or a second logger) must not collide.
    my $existing = $con->handle('runs', where => {run_uuid => $run_uuid})->first;
    unless ($existing) {
        $con->handle('runs')->insert({
            run_uuid   => $run_uuid,
            project_id => $project,
            host_id    => $host,
            ran_by     => $muser,
            status     => 'running',
            version    => $self->{+VERSION},
        });
    }

    $self->{+RUN_ROW_SEEDED} = 1;
    return;
}

# Map each runner-tracked job (job_id == job_uuid) to a jobs row.
sub _upsert_jobs ($self, $mon) {
    my $con      = $self->con;
    my $run_uuid = lc($self->{+RUN_ID});

    for my $job_id ($mon->job_ids) {
        my $job = $mon->job($job_id) or next;

        # Only this run's jobs (the snapshot is run-scoped, but be defensive).
        next if defined($job->{run_id}) && $job->{run_id} ne $self->{+RUN_ID};

        my $job_uuid = lc($job_id);
        next if $con->handle('jobs', where => {job_uuid => $job_uuid})->first;

        my $file = $job->{file};

        # Real test files only. A fileless job (the old harness-internal-log
        # job0) is no longer a job -- the harness log is a service collector now.
        next unless defined($file) && length($file);

        # test_files is project-scoped: the natural key is (project_id, filename).
        my $test_file_id = $self->_find_or_create(
            'test_files',
            {project_id => $self->{+PROJECT_ID}, filename => $file},
            'test_file_id',
        );

        $con->handle('jobs')->insert({
            job_uuid     => $job_uuid,
            run_uuid     => $run_uuid,
            test_file_id => $test_file_id,
        });
    }

    return;
}

# Fold each collector's verdict (its auditor final_state) into a job_tries row.
# The collector is a per-try unit: collector uuid -> artifact base; try_ord ->
# job_try_uuid = derive(job_uuid, try_ord). The owning job is matched by the
# collector's name (rel_file), exactly as Renderer::Base::job_for does.
sub _upsert_tries ($self, $mon) {
    my $con = $self->con;

    for my $uuid ($mon->tests) {
        my $c = $mon->collector($uuid) or next;

        my $job_uuid = $self->_job_uuid_for_collector($mon, $c) or next;
        my $try_ord  = $c->{try};
        $try_ord = 1 unless defined($try_ord) && $try_ord >= 1;    # 1-based (R10)

        my $job_try_uuid = derive_uuid(lc($job_uuid), $try_ord);

        my $fs     = $c->{final_state};
        my $status = $self->_collector_status($c);

        my $row = $self->_try_columns($fs, $try_ord, $status);

        my $existing = $con->handle('job_tries', where => {job_try_uuid => $job_try_uuid})->first;
        if ($existing) {
            # Update verdict columns once we have a final_state (or on status
            # change). QuickORM rows expose update via the handle's update.
            $con->handle('job_tries', where => {job_try_uuid => $job_try_uuid})->update($row);
        }
        else {
            $con->handle('job_tries')->insert({
                %$row,
                job_try_uuid => $job_try_uuid,
                job_uuid     => lc($job_uuid),
                try_ord      => $try_ord,
            });
        }

        $self->{+JOB_TRY_SEEN}{$uuid} = {job_uuid => lc($job_uuid), job_try_uuid => $job_try_uuid};
    }

    return;
}

# Populate the collectors table: one row per collector (test + service). The
# events artifact's uuid == collector_uuid (offset 0), so no events pointer is
# stored. A test collector carries its job_try (display_name NULL -> resolve via
# the test_file); a service collector carries NULL job_try + a display_name (the
# collector name, e.g. "harness"). Must run AFTER _upsert_tries (reads
# JOB_TRY_SEEN) and BEFORE _import_finalized (artifacts reference collectors).
sub _upsert_collectors ($self, $mon) {
    my $con      = $self->con;
    my $run_uuid = lc($self->{+RUN_ID});

    for my $uuid ($mon->collectors) {
        my $c = $mon->collector($uuid) or next;

        my $collector_uuid = lc($uuid);
        next if $con->handle('collectors', where => {collector_uuid => $collector_uuid})->first;

        my $seen         = $self->{+JOB_TRY_SEEN}{$uuid};
        my $job_try_uuid = $seen ? $seen->{job_try_uuid} : undef;

        # CHECK constraint: a collector with no try MUST be named. Service
        # collectors carry a name; fall back so the row is always valid.
        my $display_name = $job_try_uuid ? undef : ($c->{name} // 'unknown');

        $con->handle('collectors')->insert({
            collector_uuid => $collector_uuid,
            run_uuid       => $run_uuid,
            job_try_uuid   => $job_try_uuid,
            display_name   => $display_name,
        });
    }

    return;
}

# Build the verdict + status columns for a try from the auditor final_state.
sub _try_columns ($self, $fs, $try_ord, $status) {
    my %row = (status => $status);

    return \%row unless $fs;    # in-flight: result stays NULL

    my $subtests = $fs->{subtests} // [];
    my ($sp, $sf) = (0, 0);
    for my $st (@$subtests) {
        next unless ref($st) eq 'HASH';
        $st->{pass} ? $sp++ : $sf++;
    }

    $row{result}          = $fs->{pass} ? 1 : 0;
    $row{assertion_count} = $fs->{assertion_count};
    $row{pass_count}      = $fs->{pass_count};
    $row{fail_count}      = $fs->{fail_count};
    $row{subtests}        = scalar(@$subtests);
    $row{subtests_passed} = $sp;
    $row{subtests_failed} = $sf;
    $row{exit_code}       = $fs->{exit};

    return \%row;
}

# A collector status in our row vocabulary (pending/running/complete/broken/...).
sub _collector_status ($self, $c) {
    my $s = $c->{status} // 'running';
    return 'complete' if $s eq 'finalized' || $s eq 'complete';
    return 'running';
}

# ---------------------------------------------------------------------------
# Blob import: store each finalized collector's events.jsonl.zst as an artifact,
# splitting embedded binary facets into their own binary artifact rows.
# ---------------------------------------------------------------------------
sub _import_finalized ($self, $mon) {
    for my $uuid ($mon->collectors) {
        next if $self->{+ARTIFACTS_DONE}{$uuid};

        my $status = $mon->status($uuid) // '';
        next unless $status eq 'finalized';

        my $events_file = $mon->events_file($uuid);
        next unless defined($events_file) && length($events_file);

        my $ok = eval { $self->_import_collector($mon, $uuid, $events_file); 1 };
        unless ($ok) {
            $self->_record_error("Failed to import collector '$uuid' blob: $@");
        }

        # Mark done either way: a failed import is recorded; we do not retry
        # forever (the workdir-vanished case is the terminal path).
        $self->{+ARTIFACTS_DONE}{$uuid} = 1;
    }

    return;
}

sub _import_collector ($self, $mon, $uuid, $events_file) {
    my $con      = $self->con;
    my $run_uuid = lc($self->{+RUN_ID});

    my $collector_uuid = lc($uuid);

    # Events blob = offset 0, so artifact_uuid == collector_uuid (spec §244).
    my $events_uuid = derive_uuid($collector_uuid, EVENTS_OFFSET);

    # Read + (if needed) rewrite the events stream, extracting binaries.
    my ($blob, $binaries) = $self->_read_and_extract($events_file, $uuid, $run_uuid);

    my $basename = (File::Spec->splitpath($events_file))[2] // 'events.jsonl.zst';

    unless ($con->handle('artifacts', where => {artifact_uuid => $events_uuid})->first) {
        $con->handle('artifacts')->insert({
            artifact_uuid  => $events_uuid,
            run_uuid       => $run_uuid,
            collector_uuid => $collector_uuid,
            filename       => $basename,
            local_path     => $events_file,
            data           => $blob,
        });
    }

    for my $bin (@$binaries) {
        next if $con->handle('artifacts', where => {artifact_uuid => $bin->{artifact_uuid}})->first;
        $con->handle('artifacts')->insert({
            artifact_uuid  => $bin->{artifact_uuid},
            run_uuid       => $run_uuid,
            collector_uuid => $collector_uuid,
            filename       => $bin->{filename},
            data           => $bin->{data},
        });
    }

    return;
}

# Read the events file. If NO event carries a binary facet, store the raw file
# bytes verbatim (the canonical blob; no recompression). If any binary appears,
# rebuild the stream frame-by-frame with the binary bytes removed and the facet
# rewritten to reference the new binary artifact_uuid (spec §5). Returns
# ($blob, \@binaries) where each binary is {artifact_uuid, filename, data}.
sub _read_and_extract ($self, $events_file, $collector_uuid, $run_uuid) {
    require MIME::Base64;
    require Test2::Collector::Util::Zstd;
    require Test2::Collector::Util::JSON;

    # Slurp raw bytes for the no-binary fast path.
    open(my $fh, '<:raw', $events_file) or die "Could not open events file '$events_file': $!";
    my $raw = do { local $/; <$fh> };
    close($fh);

    my $reader = Test2::Collector::Util::Zstd::open_zstd_reader($events_file);

    my @binaries;
    my $bin_index  = 0;
    my $had_binary = 0;
    my @frames;

    while (defined(my $line = $reader->readline)) {
        my $rec;
        my $ok = eval { $rec = Test2::Collector::Util::JSON::decode_json($line); 1 };
        unless ($ok) {
            # Keep an undecodable record verbatim in the rebuilt stream.
            push @frames => $line;
            next;
        }

        my $fd  = ref($rec) eq 'HASH' ? $rec->{facet_data} : undef;
        my $bin = (ref($fd) eq 'HASH') ? $fd->{binary} : undef;

        if ($bin && ref($bin) eq 'ARRAY' && @$bin) {
            $had_binary = 1;
            for my $file (@$bin) {
                next unless ref($file) eq 'HASH';
                my $data = delete $file->{data};
                $bin_index++;
                my $artifact_uuid = derive_uuid(lc($collector_uuid), $bin_index);

                push @binaries => {
                    artifact_uuid => $artifact_uuid,
                    filename      => $file->{filename} // "binary-$bin_index",
                    data          => defined($data) ? MIME::Base64::decode_base64($data) : '',
                };

                # Rewrite the event's facet: bytes removed, reference added.
                $file->{artifact_uuid} = $artifact_uuid;
                $file->{extracted}     = 1;
            }
        }

        push @frames => Test2::Collector::Util::JSON::encode_json($rec);
    }

    # No binaries: the on-disk blob IS canonical -- store it verbatim.
    return ($raw, []) unless $had_binary;

    # Rebuild the stream: one self-contained zstd frame per event (the recorder's
    # format), so the stored blob is read back identically.
    my $blob = '';
    $blob .= Test2::Collector::Util::Zstd::compress_blob($_ . "\n") for @frames;

    return ($blob, \@binaries);
}

# ---------------------------------------------------------------------------
# Run-row finalization: fold the resolved jobs into runs/jobs counters + status.
# ---------------------------------------------------------------------------
sub _finalize_run_row ($self) {
    return unless $self->{+RUN_ROW_SEEDED};

    my $con      = $self->con;
    my $run_uuid = lc($self->{+RUN_ID});

    # Fold jobs.passed/failed from their tries (any-try-passed), then runs counters.
    my ($passed, $failed, $retried) = (0, 0, 0);

    my @jobs = $con->handle('jobs', where => {run_uuid => $run_uuid})->all;
    for my $job (@jobs) {
        my $job_uuid = lc($job->field('job_uuid'));
        my @tries    = $con->handle('job_tries', where => {job_uuid => $job_uuid})->all;
        next unless @tries;

        my $any_pass = 0;
        my $try_count = 0;
        for my $try (@tries) {
            $try_count++;
            my $res = $try->field('result');
            $any_pass = 1 if defined($res) && $res;
        }

        # Only fold resolved jobs (all tries have a verdict). An in-flight try
        # leaves the job unresolved.
        my $resolved = 1;
        for my $try (@tries) {
            $resolved = 0 unless defined $try->field('result');
        }
        next unless $resolved;

        my $job_passed = $any_pass ? 1 : 0;
        $con->handle('jobs', where => {job_uuid => $job_uuid})->update({
            passed => $job_passed,
            failed => $job_passed ? 0 : 1,
        });

        $job_passed ? $passed++ : $failed++;
        $retried++ if $try_count > 1;
    }

    my $status = $self->{+TERMINAL_ERROR} ? 'broken' : 'complete';

    $con->handle('runs', where => {run_uuid => $run_uuid})->update({
        passed  => $passed,
        failed  => $failed,
        retried => $retried,
        status  => $status,
    });

    return;
}

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# get_or_create on a natural key; returns the integer PK.
sub _find_or_create ($self, $table, $natural, $pk_col) {
    my $con = $self->con;

    my $row = $con->handle($table, where => $natural)->first;
    return $row->field($pk_col) if $row;

    my $new = $con->handle($table)->insert($natural);
    return $new->field($pk_col);
}

# Map a collector to its job_uuid (= job_id). The collector's name is the
# rel_file; match it against a runner-tracked job's file (abs2rel), exactly like
# Renderer::Base::job_for.
sub _job_uuid_for_collector ($self, $mon, $c) {
    my $name = $c->{name} // return undef;

    for my $job_id ($mon->job_ids) {
        my $job = $mon->job($job_id) or next;
        my $file = $job->{file};
        next unless defined $file;

        return $job_id if $file eq $name;
        return $job_id if eval { File::Spec->abs2rel($file) eq $name };
    }

    return undef;
}

sub _os_username ($self) {
    return getpwuid($<) // $ENV{USER} // $ENV{LOGNAME} // 'unknown'
        if $^O ne 'MSWin32';
    return $ENV{USERNAME} // $ENV{USER} // 'unknown';
}

sub _project_name ($self) {
    my $dir = $self->{+WORKDIR};
    my $base = (File::Spec->splitpath(File::Spec->rel2abs($dir)))[1] // '';
    $base =~ s{/+$}{};
    my @parts = grep { length } File::Spec->splitdir($base);
    return $parts[-1] // 'unknown';
}

sub _record_error ($self, $msg) {
    push @{$self->{+ERRORS}} => $msg;
    warn "DB logger: $msg\n";
    return;
}

sub _terminal_error ($self, $msg) {
    $self->{+TERMINAL_ERROR} = $msg;
    $self->_record_error($msg);
    return;
}

sub errors         ($self) { return $self->{+ERRORS} // [] }
sub terminal_error ($self) { return $self->{+TERMINAL_ERROR} }

1;

__END__

=pod

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

package Test2::Harness2::Collector::Recorder::DB;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use Time::HiRes qw/time/;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

# Right now we have 2 types, "service" and "test job". This does not exactly represent the types. We have 'simple' (services use this) and 'test' (test jobs use this). It is binary, and new types are not likely to be added later. Switch this to an is_test flag that is boolean. Services (and most future collector uses) will keep the flag false, test jobs will set it true. Make sure the database table for collectors also reflects this binary choice and is_test flag.
use Object::HashBase qw{
    <handle
    <runner_id
    <name
    <type
    <pid
    <workdir
    <start_time
    +collector_id
    +events_artifact_id
    +events_path
    +events_writer
    +finalized
};

use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Recorder';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Recorder::DB - Database-backed recorder for
the collector pipeline.

=head1 DESCRIPTION

Implements L<Test2::Harness2::Collector::Role::Recorder> against the
harness's database. On construction it inserts the C<collectors> row
representing this collector and an C<artifacts> row pointing at the
in-progress C<events.jsonl.zst> file on disk (via C<local_path>). Events
are appended to that file as one self-contained zstd frame per call to
C<record_event>. Compressed bursts the parser captured at the wire are
passed through verbatim via the writer's C<print_raw_frame>; otherwise
the event is JSON-encoded and zstd-compressed on the way out.

On C<finalize> the recorder reads the events file back, writes its
contents to the artifact row's C<content> column, clears C<local_path>,
unlinks the on-disk file, and stamps C<finalized> on the C<collectors>
row.

State transitions land as future column updates on the collector's
owning entity (C<job_tries> for test jobs, C<service_state> for
services). The mapping is wired up by the surrounding service /
scheduler work; this recorder accepts C<record_state> calls and
ignores them for now so the collector pipeline can be exercised
end-to-end against a database before that wiring lands.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Recorder::DB;

    my $r = Test2::Harness2::Collector::Recorder::DB->new(
        handle    => $harness_handle,
        runner_id => $runner->runner_id,
        name      => $unique_collector_name,
        type      => 'test job',
        workdir   => $workdir_path,
    );

    $r->set_watched($child_pid);   # after the collector fork
    $r->record_event($event);
    $r->record_exit($wait_status);
    $r->finalize;

=head1 ATTRIBUTES

=over 4

=item handle (required)

The L<Test2::Harness2> handle that owns the database.

=item runner_id (required)

The C<runners.runner_id> this collector belongs to.

=item name (required)

The collector's name, unique per runner.

=item type (required)

C<'service'>, C<'test job'>, etc.

=item pid

The collector process's pid. Defaults to C<$$>.

=item workdir (required)

Working directory the recorder writes its in-progress events file
under. The file lives at C<${workdir}/events/<UUID>.jsonl.zst> until
C<finalize> migrates its contents into the artifact row.

=item start_time

Wall-clock start timestamp of the collected process. Defaults to
C<Time::HiRes::time()>.

=back

=cut

sub init {
    my $self = shift;

    croak "'handle' is a required attribute"    unless $self->{+HANDLE};
    croak "'runner_id' is a required attribute" unless defined $self->{+RUNNER_ID};
    croak "'name' is a required attribute"      unless defined $self->{+NAME};
    croak "'type' is a required attribute"      unless defined $self->{+TYPE};
    croak "'workdir' is a required attribute"   unless defined $self->{+WORKDIR};

    $self->{+PID}        //= $$;
    $self->{+START_TIME} //= time();
    $self->{+FINALIZED} = 0;

    make_path($self->{+WORKDIR}) unless -d $self->{+WORKDIR};
    my $events_dir = File::Spec->catdir($self->{+WORKDIR}, 'events');
    make_path($events_dir) unless -d $events_dir;

    my $event_file_path = File::Spec->catfile($events_dir, gen_uuid() . '.jsonl.zst');
    $self->{+EVENTS_PATH} = $event_file_path;

    my ($collector_row) = $self->{+HANDLE}->insert(collectors => {
        runner_id  => $self->{+RUNNER_ID},
        name       => $self->{+NAME},
        pid        => $self->{+PID},
        type       => $self->{+TYPE},
        start_time => $self->{+START_TIME},
    });
    $self->{+COLLECTOR_ID} = $collector_row->collector_id;

    my ($artifact_row) = $self->{+HANDLE}->insert(artifacts => {
        collector_id => $self->{+COLLECTOR_ID},
        filename     => 'events.jsonl.zst',
        local_path   => $event_file_path,
    });
    $self->{+EVENTS_ARTIFACT_ID} = $artifact_row->artifact_id;

    $self->{+EVENTS_WRITER} = open_zstd_writer($event_file_path);
}

=head1 PUBLIC METHODS

=over 4

=item $r->set_watched($pid)

Update the C<collectors.watched> column with the pid of the collected
process. Called by the collector once it has forked the child.

=back

=cut

sub set_watched {
    my ($self, $pid) = @_;
    $self->_assert_open;

    my $dbh = $self->{+HANDLE}->dbh;
    $dbh->do(
        "UPDATE collectors SET watched = ? WHERE collector_id = ?",
        undef, $pid, $self->{+COLLECTOR_ID},
    );
    return;
}

=over 4

=item $r->record_event($event)

Append the event to the in-progress events file as one self-contained
zstd frame. Passes the captured-from-wire compressed bytes through
when the parser stashed them on the event's C<compressed_form>;
otherwise encodes the event as JSON and lets the writer compress.

=back

=cut

sub record_event {
    my ($self, $event) = @_;
    $self->_assert_open;

    my $w = $self->{+EVENTS_WRITER} or die "events writer is gone";

    my $compressed = delete $event->{compressed_form};

    my $ok = eval {
        if (defined $compressed) {
            $w->print_raw_frame($compressed);
        }
        else {
            $w->say(encode_json($event));
        }
        1;
    };
    my $err = $@;

    $event->{compressed_form} = $compressed if defined $compressed;

    die $err unless $ok;
    return;
}

=over 4

=item $r->record_state($state, $extra)

No-op for now. Reserved for future column updates on the collector's
owning row.

=back

=cut

sub record_state {
    my ($self, $state, $extra) = @_;
    $self->_assert_open;
    return;
}

=over 4

=item $r->record_exit($exit)

Update the C<collectors.exit_code> and C<collectors.stop_time>
columns with the collected process's wait-status and the current
timestamp.

=back

=cut

sub record_exit {
    my ($self, $exit) = @_;
    $self->_assert_open;

    my $dbh = $self->{+HANDLE}->dbh;
    $dbh->do(
        "UPDATE collectors SET exit_code = ?, stop_time = ? WHERE collector_id = ?",
        undef, $exit, time(), $self->{+COLLECTOR_ID},
    );
    return;
}

=over 4

=item $r->record_artifact(\%spec)

Insert an additional artifact row owned by this collector. C<%spec>
carries at least one of C<content> / C<local_path> plus an optional
C<filename> (default: C<'artifact'>).

=back

=cut

sub record_artifact {
    my ($self, $spec) = @_;
    $self->_assert_open;

    croak "record_artifact requires a hashref" unless ref($spec) eq 'HASH';

    my %row = (
        collector_id => $self->{+COLLECTOR_ID},
        filename     => $spec->{filename} // $spec->{name} // 'artifact',
    );
    $row{content}    = $spec->{content}    if defined $spec->{content};
    $row{local_path} = $spec->{local_path} if defined $spec->{local_path};

    my ($artifact_row) = $self->{+HANDLE}->insert(artifacts => \%row);
    return $artifact_row;
}

=over 4

=item $r->finalize

Close the events writer, read the bytes back, migrate them into the
artifact row's C<content>, clear C<local_path>, unlink the on-disk
file, and stamp C<collectors.finalized>. Idempotent.

=back

=cut

sub finalize {
    my $self = shift;
    return if $self->{+FINALIZED};

    if (my $w = delete $self->{+EVENTS_WRITER}) {
        $w->close;
    }

    $self->_migrate_events_artifact;

    my $dbh = $self->{+HANDLE}->dbh;
    $dbh->do(
        "UPDATE collectors SET finalized = ? WHERE collector_id = ?",
        undef, time(), $self->{+COLLECTOR_ID},
    );

    $self->{+FINALIZED} = 1;
    return;
}

sub _migrate_events_artifact {
    my $self = shift;

    my $path = $self->{+EVENTS_PATH};
    return unless defined $path && -e $path;

    open(my $fh, '<:raw', $path) or die "Failed to read $path: $!";
    local $/;
    my $bytes = <$fh>;
    close($fh);

    my $dbh = $self->{+HANDLE}->dbh;
    my $sth = $dbh->prepare(
        "UPDATE artifacts SET content = ?, local_path = NULL WHERE artifact_id = ?"
    );
    $sth->bind_param(1, $bytes, $self->{+HANDLE}->blob_sql_type);
    $sth->bind_param(2, $self->{+EVENTS_ARTIFACT_ID});
    $sth->execute;

    unlink($path) or warn "Failed to unlink $path: $!";
    return;
}

sub _assert_open {
    my $self = shift;
    croak "Recorder::DB already finalized" if $self->{+FINALIZED};
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut

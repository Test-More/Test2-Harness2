package Test2::Harness2::Collector::Recorder::Files;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use IO::Handle;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <dir
    +events_fh
    +state_fh
    +artifacts_fh
    +finalized
};

use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Recorder';

sub init {
    my $self = shift;

    croak "'dir' is a required attribute"
        unless defined $self->{+DIR} && length $self->{+DIR};

    make_path($self->{+DIR}) unless -d $self->{+DIR};

    open($self->{+EVENTS_FH}, '>>', $self->_path('events.jsonl'))
        or die "Failed to open events.jsonl: $!";
    open($self->{+STATE_FH}, '>>', $self->_path('state.jsonl'))
        or die "Failed to open state.jsonl: $!";

    $self->{+EVENTS_FH}->autoflush(1);
    $self->{+STATE_FH}->autoflush(1);

    $self->{+FINALIZED} = 0;
}

sub _path {
    my ($self, $name) = @_;
    return File::Spec->catfile($self->{+DIR}, $name);
}

sub _assert_open {
    my $self = shift;
    croak "Recorder already finalized" if $self->{+FINALIZED};
}

sub record_event {
    my ($self, $event) = @_;
    $self->_assert_open;

    my $compressed = delete $event->{compressed_form};

    my $ok  = eval { print {$self->{+EVENTS_FH}} encode_json($event), "\n"; 1 };
    my $err = $@;

    $event->{compressed_form} = $compressed if defined $compressed;

    die $err unless $ok;
    return;
}

sub record_state {
    my ($self, $state, $extra) = @_;
    $self->_assert_open;

    my %row = (state => $state, stamp => time());
    $row{extra} = $extra if defined $extra;

    print {$self->{+STATE_FH}} encode_json(\%row), "\n";
    return;
}

sub record_exit {
    my ($self, $exit, $info) = @_;
    $self->_assert_open;

    my $path = $self->_path('exit');
    open(my $fh, '>', $path) or die "Failed to write $path: $!";
    print {$fh} "$exit\n";
    close($fh) or die "Failed to close $path: $!";

    if ($info && $info->{orphaned}) {
        my $marker = $self->_path('orphaned');
        open(my $ofh, '>', $marker) or die "Failed to write $marker: $!";
        print {$ofh} time(), "\n";
        close($ofh) or die "Failed to close $marker: $!";
    }

    if ($info && $info->{timed_out}) {
        my $marker = $self->_path('timed_out');
        open(my $tfh, '>', $marker) or die "Failed to write $marker: $!";
        print {$tfh} $info->{timed_out}, " ", time(), "\n";
        close($tfh) or die "Failed to close $marker: $!";
    }

    return;
}

sub record_artifact {
    my ($self, $spec) = @_;
    $self->_assert_open;

    croak "record_artifact requires a hashref" unless ref($spec) eq 'HASH';

    unless ($self->{+ARTIFACTS_FH}) {
        open($self->{+ARTIFACTS_FH}, '>>', $self->_path('artifacts.jsonl'))
            or die "Failed to open artifacts.jsonl: $!";
        $self->{+ARTIFACTS_FH}->autoflush(1);
    }

    print {$self->{+ARTIFACTS_FH}} encode_json($spec), "\n";
    return;
}

sub finalize {
    my $self = shift;
    return if $self->{+FINALIZED};

    close($self->{+EVENTS_FH})    if $self->{+EVENTS_FH};
    close($self->{+STATE_FH})     if $self->{+STATE_FH};
    close($self->{+ARTIFACTS_FH}) if $self->{+ARTIFACTS_FH};

    my $marker = $self->_path('finalized');
    open(my $fh, '>', $marker) or die "Failed to write $marker: $!";
    print {$fh} time(), "\n";
    close($fh) or die "Failed to close $marker: $!";

    $self->{+FINALIZED} = 1;
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Recorder::Files - Plain on-disk recorder for
the collector pipeline.

=head1 DESCRIPTION

A database-free recorder. Writes the collected stream as JSONL files under
a caller-supplied directory. Used by the development driver
(C<t/scripts/collector>) and by integration tests that exercise the
collector pipeline without standing up a database.

The recorder writes:

=over 4

=item F<events.jsonl>

JSON-encoded event per line. Each event is the L<Test2::Harness2::Event>
the auditor (or the parser, when no auditor is configured) delivered.

=item F<state.jsonl>

JSON-encoded state transition per line. Each line carries C<state>, a
hi-res C<stamp>, and an optional C<extra> hashref of state-specific
detail.

=item F<exit>

Single line holding the raw wait-status of the collected process.

=item F<orphaned>

Single-line hi-res timestamp. Written by L</record_exit> when the
collector flagged the run as orphaned (collected process exited but
its pipes stayed open past the orphan-timeout). Absent when the run
was not orphaned.

=item F<timed_out>

Single-line C<"$kind $stamp"> (e.g. C<"silence 1715890432.12">).
Written by L</record_exit> when the collector forcibly killed the
collected test job because it hit the silence or lifetime timeout.
Absent when no timeout fired.

=item F<artifacts.jsonl>

JSON-encoded artifact spec per line. Written only when the auditor or
parser flags an external artifact via L</record_artifact>. The file is
not created when no artifact is recorded.

=item F<finalized>

Single line holding a hi-res timestamp; written by L</finalize>. Its
presence is the on-disk equivalent of the C<finalized> flag on a
database-backed recorder's C<collectors> row.

=back

The C<dir> attribute is required; callers pick the location (typically
a per-collector subdirectory under a workdir, or a fresh
L<File::Temp::tempdir>). The directory is created on construction if it
does not already exist.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Recorder::Files;

    my $r = Test2::Harness2::Collector::Recorder::Files->new(dir => $path);

    $r->record_state(starting => { pid => $$ });
    $r->record_event($event);
    $r->record_artifact({name => 'screenshot.png', local_path => $img});
    $r->record_exit(0);
    $r->finalize;

=head1 ATTRIBUTES

=over 4

=item dir (required)

Directory the recorder writes into. Created on construction if missing.

=back

=head1 PUBLIC METHODS

=over 4

=item $r->record_event($event)

Append the event as one JSON line to F<events.jsonl>. The event's
C<compressed_form> slot (zstd bytes captured at the wire) is removed
before encoding and restored on the event afterward; the Files recorder
does not preserve the compressed form on disk.

=item $r->record_state($state, $extra)

Append a state-transition row to F<state.jsonl>. C<$state> is a short
identifier; C<$extra> is an optional hashref attached as-is.

=item $r->record_exit($exit, \%info)

Write the raw wait-status to F<exit>. Overwrites any previous content
(the collector records the exit exactly once).

If C<%info> has a true C<orphaned> flag, additionally writes an
F<orphaned> marker file (single-line hi-res timestamp). The marker's
presence is the on-disk equivalent of the C<orphaned> column on a
database-backed recorder's job-try row.

If C<%info> has a non-zero C<timed_out> value, additionally writes a
F<timed_out> marker file holding C<"$kind $stamp"> (e.g.
C<"silence 1715890432.12">). The marker's presence is the on-disk
equivalent of the C<timed_out> column on a database-backed
recorder's job-try row.

=item $r->record_artifact(\%spec)

Append the artifact spec as one JSON line to F<artifacts.jsonl>. The
file is created lazily on first call.

=item $r->finalize

Close all open files, drop the F<finalized> marker into the recorder's
directory, and refuse further writes. Calling C<finalize> twice is a
no-op.

=back

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

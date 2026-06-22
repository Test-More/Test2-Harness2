package App::Yath2::RenderLoop::JSONLFileProducer;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Util::File::JSONL;

use Test2::Harness2::Util::HashBase qw{
    <log_file
    <jobs
    +stream
    +done
    <final_data
    <tests_seen
    <asserts_seen
};

use Role::Tiny::With;
with 'App::Yath2::RenderLoop::Producer';

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::RenderLoop::JSONLFileProducer - Render-loop producer that replays a
flat C<.jsonl> event log.

=head1 DESCRIPTION

A L<App::Yath2::RenderLoop::Producer> that reads a previously-written flat
C<.jsonl[.gz|.bz2]> event log and yields its recorded events back in file order,
so the C<replay> command renders an archived run through the same
L<App::Yath2::RenderLoop> the live commands use. The events were already ordered
and rolled up when the log was written, so this producer does no per-job ordering
of its own: it streams the file, captures the recorded C<harness_final> rollup,
and (optionally) limits rendering to a set of job ids.

This is a transition shim: it keeps C<replay> working while the durable log moves
to a database. It is replaced by the database-backed archive producer once the
log layer is rewritten.

=head1 SYNOPSIS

    my $producer = App::Yath2::RenderLoop::JSONLFileProducer->new(
        log_file => $path,
        jobs     => {job_id => 1, ...},   # optional filter
    );

    my $loop = App::Yath2::RenderLoop->new(renderers => $renderers, producer => $producer);
    $loop->start;
    my $final = $loop->final_data;

=head1 ATTRIBUTES

=over 4

=item log_file

The path to the C<.jsonl[.gz|.bz2]> log to replay.

=item jobs

An optional hashref of C<< job_id => 1 >> (and/or test file path) limiting which
jobs are rendered; when set, events for other jobs are skipped (the recorded
C<harness_final> always passes through).

=item final_data

=item tests_seen

=item asserts_seen

Populated as the log is consumed: the recorded run rollup and the launched-test /
assertion tallies, read by the loop after it finishes.

=back

=cut

sub init ($self) {
    croak "log_file is required" unless defined $self->{+LOG_FILE} && length $self->{+LOG_FILE};

    $self->{+TESTS_SEEN}   //= 0;
    $self->{+ASSERTS_SEEN} //= 0;
    $self->{+DONE} = 0;

    return;
}

=head1 PUBLIC METHODS

=over 4

=item @events = $producer->poll

Read up to a batch of recorded events from the log, tallying launched tests and
assertions, capturing the C<harness_final> rollup, and applying the optional job
filter. Returns the events to render (the C<harness_final> event is captured for
C<final_data> and not re-rendered, matching the original replay loop). An empty
return with C<done> true marks end of file.

=item $bool = $producer->done

True once the log has been fully read.

=back

=cut

sub poll ($self) {
    return () if $self->{+DONE};

    my @events = $self->stream->poll(max => 1000);
    unless (@events) {
        $self->{+DONE} = 1;
        return ();
    }

    my $jobs = $self->{+JOBS};

    my @out;
    for my $e (@events) {
        next unless defined $e;

        my $fd = $e->{facet_data} // {};

        $self->{+TESTS_SEEN}++   if $fd->{harness_job_launch};
        $self->{+ASSERTS_SEEN}++ if $fd->{assert};

        $self->_match_job($e, $fd) if $jobs;

        if (my $final = $fd->{harness_final}) {
            $self->{+FINAL_DATA} = $final;
            next;
        }

        next if $jobs && !$jobs->{$e->{job_id} // ''};

        push @out => $e;
    }

    return @out;
}

sub done ($self) { return $self->{+DONE} ? 1 : 0 }

=head1 PRIVATE METHODS

=over 4

=item $self->stream

The cached L<Test2::Harness2::Util::File::JSONL> reader for the log file.

=item $self->_match_job($event, $facet_data)

Resolve a job's id from its C<harness_job_start> / C<harness_job_queued> file
fields when the caller filtered by test-file path, marking that job id selected so
its later events pass the filter (the original replay behavior).

=back

=cut

sub stream ($self) {
    return $self->{+STREAM} //= Test2::Harness2::Util::File::JSONL->new(name => $self->{+LOG_FILE});
}

sub _match_job ($self, $e, $fd) {
    my $jobs = $self->{+JOBS} or return;

    my $job_id = $e->{job_id} // return;
    return if $jobs->{$job_id};

    my $f = $fd->{harness_job_start} // $fd->{harness_job_queued} or return;

    for my $field (qw/rel_file abs_file file/) {
        my $file = $f->{$field} or next;
        next unless $jobs->{$file};
        $jobs->{$job_id} = 1;
        return;
    }

    return;
}

1;

__END__

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

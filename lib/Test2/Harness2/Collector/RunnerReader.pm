package Test2::Harness2::Collector::RunnerReader;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Test2::Collector::Util::Zstd qw/open_zstd_reader/;
use Test2::Collector::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Event;

use Test2::Harness2::Util::HashBase qw{
    <run_id <events_file
    +reader +done +last_stamp
};

# Tail the non-test collector that wraps the `yath test` runner
# (runner-events.jsonl.zst, recorded by App::Yath2::Command::test start_runner)
# and re-emit its records as run-level harness events. This is the runner-stream
# sibling of Test2::Harness2::Collector::JobReader: it carries a run_id but no
# job_id (runner output is run-level, job_id 0 like the gatherer's synthetic
# _harness_event), produces no harness_job_exit/harness_job_end (those are
# job-only), and reaches done on the runner's terminal harness_process_exit.
#
# Renderer contract: the OLD output.log/error.log tailer surfaced runner stdout
# as info {tag => 'INTERNAL', important => 1} and stderr as the same plus
# {debug => 1}. Test2-Collector's IOParser instead tags each line STDOUT/STDERR
# (debug => 1 for STDERR). We remap those info entries to the historical
# INTERNAL shape so the renderer shows runner output exactly as before.

sub init ($self) {
    croak "events_file is required" unless defined $self->{+EVENTS_FILE};
}

sub done ($self) { $self->{+DONE} }

sub reader ($self) {
    return $self->{+READER} if $self->{+READER};
    # The runner may not have created its events file yet (it is just starting).
    # Return undef so poll() yields () and the caller keeps waiting -- never die.
    return undef unless -e $self->{+EVENTS_FILE};
    return $self->{+READER} = open_zstd_reader($self->{+EVENTS_FILE});
}

# Return up to $max wrapped harness events; empty list if nothing new yet.
sub poll ($self, $max = undef) {
    return () if $self->{+DONE};

    my $reader = $self->reader or return ();

    my @out;
    while (!defined($max) || @out < $max) {
        my $line = $reader->readline;
        last unless defined $line;

        # The file may still be being written; a corrupt/partial record must not
        # abort the poll. Surface it as a diagnostic and carry on.
        my $rec;
        my $ok  = eval { $rec = decode_json($line); 1 };
        my $err = $@;
        unless ($ok) {
            push @out => $self->_wrap({info => [{tag => 'INTERNAL', debug => 1, important => 1, details => "Failed to decode runner events record: $err"}]});
            next;
        }

        my $fd = $rec->{facet_data} or next;

        # Map the IOParser's STDOUT/STDERR info entries to the historical runner
        # INTERNAL shape the renderer expects (tag => INTERNAL, important => 1;
        # debug => 1 for stderr). from_stream is internal bookkeeping; drop it.
        if (my $info = $fd->{info}) {
            for my $i (@$info) {
                next unless defined $i->{tag};
                if ($i->{tag} eq 'STDOUT') {
                    $i->{tag}       = 'INTERNAL';
                    $i->{important} = 1;
                    delete $i->{debug};
                }
                elsif ($i->{tag} eq 'STDERR') {
                    $i->{tag}       = 'INTERNAL';
                    $i->{important} = 1;
                    $i->{debug}     = 1;
                }
            }
        }
        delete $fd->{from_stream};

        # The runner's synthetic process-exit is the terminal record. Keep it as
        # a renderable info line (so a non-zero runner exit is visible) and mark
        # done -- there are no records after it.
        if (my $px = $fd->{harness_process_exit}) {
            $self->{+LAST_STAMP} = $px->{stamp} if defined $px->{stamp};
            push @out => $self->_wrap($fd);
            $self->{+DONE} = 1;
            last;
        }

        # Skip otherwise-empty records (e.g. a record that carried only a
        # from_stream facet we just dropped) so we don't emit blank events.
        next unless keys %$fd;

        push @out => $self->_wrap($fd);
    }

    return @out;
}

sub _wrap ($self, $fd) {
    return Test2::Harness2::Event->new(
        event_id   => gen_uuid(),
        job_id     => 0,
        job_try    => undef,
        run_id     => $self->{+RUN_ID},
        stamp      => $self->{+LAST_STAMP} // time,
        facet_data => $fd,
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::RunnerReader - Tail the non-test collector that
wraps the C<yath test> runner and emit wrapped harness events.

=head1 DESCRIPTION

Reads the C<runner-events.jsonl.zst> file produced by the non-test
L<Test2::Collector> that wraps the C<yath test> runner process, turning each
record into a run-level L<Test2::Harness2::Event>. Runner stdout/stderr (carried
by the collector's IOParser as STDOUT/STDERR-tagged C<info> entries) are remapped
to the historical C<INTERNAL>-tagged shape the renderer expects, and the reader
reaches C<done> on the runner's synthetic C<harness_process_exit>.

This is the runner-stream sibling of L<Test2::Harness2::Collector::JobReader>:
same C<*.jsonl.zst> reader path, but run-level (no C<job_id>) and with no
job-completion facet synthesis.

=head1 SYNOPSIS

    my $reader = Test2::Harness2::Collector::RunnerReader->new(
        run_id      => $run_id,
        events_file => "$workdir/runner-events.jsonl.zst",
    );

    until ($reader->done) {
        my @events = $reader->poll(1000);
        process($_) for @events;
    }

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2024 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

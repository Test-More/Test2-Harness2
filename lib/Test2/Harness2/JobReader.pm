package Test2::Harness2::JobReader;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Test2::Collector::Util::Zstd qw/open_zstd_reader/;
use Test2::Collector::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Event;

use Test2::Harness2::Util::HashBase qw{
    <job_id <job_try <run_id <file <events_file
    +reader +done +last_stamp
};

sub init ($self) {
    croak "job_id is required"      unless defined $self->{+JOB_ID};
    croak "events_file is required" unless defined $self->{+EVENTS_FILE};
    $self->{+JOB_TRY} //= 0;
}

sub done ($self) { $self->{+DONE} }

sub reader ($self) {
    return $self->{+READER} if $self->{+READER};
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
        # abort the poll. Surface it as a diagnostic event and carry on.
        my $rec;
        my $ok  = eval { $rec = decode_json($line); 1 };
        my $err = $@;
        unless ($ok) {
            push @out => $self->_wrap({info => [{tag => 'INTERNAL', debug => 1, important => 1, details => "Failed to decode events record: $err"}]});
            next;
        }

        my $fd = $rec->{facet_data} or next;

        # Test2-Collector already attaches its own harness_job_exit facet to the
        # process-exit record (Test2::Collector::Auditor::_subtest_process_exit),
        # but in the collector's own shape. The harness renderer/rollup expect
        # the harness-canonical shape (job_id, retry, code/signal, ...). Replace
        # it in-place on the SAME record from the harness_process_exit data, so
        # there is exactly ONE harness_job_exit per job and it carries the shape
        # the harness consumes. (Emitting a second event here is what made
        # concurrency.t see two exits per job.)
        #
        # NOTE: do NOT mark the reader done here. Test2-Collector records
        # harness_final_state AFTER harness_process_exit (Auditor: process-exit
        # event, then 'completed' transition, then the final-state event). If
        # process-exit lands on the last slot of a bounded poll batch, ending on
        # it would skip final_state on the next call (DONE short-circuits poll),
        # so no harness_job_end would ever be emitted and the run would report a
        # completed job as "never ran". Completion is keyed to final_state below.
        if (my $px = $fd->{harness_process_exit}) {
            $fd->{harness_job_exit} = $self->_job_exit_facet($px);
        }

        push @out => $self->_wrap($fd);

        # final_state is the true terminal record. Synthesize the
        # harness_job_end facet the renderer/rollup expect and mark done.
        if (my $fs = $fd->{harness_final_state}) {
            push @out => $self->_wrap({harness_job_end => $self->_job_end_facet($fs)});
            $self->{+DONE} = {retry => 0};
            last;
        }
    }

    # Once done, close and drop the underlying zstd reader so a finished job does
    # not hold an open fd for the rest of the run. Under a live tail with more
    # files than the fd rlimit, keeping every finished reader open hit EMFILE
    # mid-run (TODO-141 finding 96). done short-circuits poll(), so nothing reopens it.
    if ($self->{+DONE} && $self->{+READER}) {
        my $reader = delete $self->{+READER};
        $reader->close if $reader->can('close');
    }

    return @out;
}

sub _wrap ($self, $fd) {
    my $stamp = $self->_stamp_for($fd);

    return Test2::Harness2::Event->new(
        event_id   => gen_uuid(),
        job_id     => $self->{+JOB_ID},
        job_try    => $self->{+JOB_TRY},
        run_id     => $self->{+RUN_ID},
        stamp      => $stamp,
        facet_data => $fd,
    );
}

sub _stamp_for ($self, $fd) {
    for my $f (qw/harness_process_exit harness_final_state harness_state_transition/) {
        return $self->{+LAST_STAMP} = $fd->{$f}{stamp} if $fd->{$f} && defined $fd->{$f}{stamp};
    }
    return $self->{+LAST_STAMP} = $fd->{trace}{stamp} if $fd->{trace} && defined $fd->{trace}{stamp};
    return $self->{+LAST_STAMP};
}

sub _job_exit_facet ($self, $px) {
    return {
        details => "Test script exited " . ($px->{all} // 0),
        exit    => $px->{all} // 0,
        code    => $px->{err} // 0,
        signal  => $px->{sig} // 0,
        dumped  => $px->{dmp} // 0,
        retry   => 0,
        job_id  => $self->{+JOB_ID},
        job_try => $self->{+JOB_TRY},
        stamp   => $px->{stamp},
        times   => $px->{times},
    };
}

sub _job_end_facet ($self, $fs) {
    my $file = $self->{+FILE};

    # A skip-all test declares a plan with a zero count (e.g. "1..0 # SKIP
    # reason"). Test2-Collector carries the whole plan facet through to its
    # final-state verdict, so derive the skip reason here the way the 1.0
    # auditor did. The renderer renders SKIPPED off this field.
    # Test2-Collector's plan facet uses `skip` as a boolean flag and carries the
    # human-readable reason in `details` (matching the 1.0 Auditor::Watcher).
    my $skip;
    if (my $plan = $fs->{plan}) {
        $skip = $plan->{details} || "No reason given"
            unless $plan->{count};
    }

    return {
        file     => $file,
        rel_file => defined($file) ? File::Spec->abs2rel($file) : undef,
        abs_file => defined($file) ? File::Spec->rel2abs($file) : undef,
        retry    => 0,
        fail     => $fs->{pass} ? 0 : 1,
        skip     => $skip,
        # A bail-out / halt reason rides through on the audited final state. Carry
        # it so the gatherer rollup can list the job under "Halted".
        halt     => $fs->{halt},
        stamp    => $fs->{stamp},
        times    => $fs->{times},
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::JobReader - Tail a Test2-Collector events.jsonl.zst
file and emit wrapped harness events.

=head1 DESCRIPTION

Reads a C<.jsonl.zst> file produced by L<Test2::Collector::Recorder::Zstd> and
turns each record into a L<Test2::Harness2::Event>, synthesizing the
C<harness_job_exit> and C<harness_job_end> facets that the renderer and rollup
expect. This replaces the old JobDir approach of scraping stdout/stderr/exit
files and parsing TAP.

=head1 SYNOPSIS

    my $reader = Test2::Harness2::JobReader->new(
        job_id      => $job_id,
        job_try     => $job_try,
        run_id      => $run_id,
        events_file => "$job_dir/events.jsonl.zst",
        file        => $test_file,
    );

    until ($reader->done) {
        my @events = $reader->poll(1000);
        process($_) for @events;
    }

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

Copyright 2024 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

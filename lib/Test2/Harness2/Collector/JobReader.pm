package Test2::Harness2::Collector::JobReader;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();
use Test2::Collector::Util::Zstd qw/open_zstd_reader/;
use Test2::Collector::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Event;

use Test2::Harness2::Util::HashBase qw{
    <job_id <job_try <run_id <file <events_file
    +reader +done +last_stamp +final_state
};

sub init {
    my $self = shift;
    die "job_id is required"      unless defined $self->{+JOB_ID};
    die "events_file is required" unless defined $self->{+EVENTS_FILE};
    $self->{+JOB_TRY} //= 0;
}

sub done { $_[0]->{+DONE} }

sub reader {
    my $self = shift;
    return $self->{+READER} if $self->{+READER};
    return undef unless -e $self->{+EVENTS_FILE};
    return $self->{+READER} = open_zstd_reader($self->{+EVENTS_FILE});
}

# Return up to $max wrapped harness events; empty list if nothing new yet.
sub poll {
    my $self = shift;
    my ($max) = @_;

    return () if $self->{+DONE};

    my $reader = $self->reader or return ();

    my @out;
    while (!defined($max) || @out < $max) {
        my $line = $reader->readline;
        last unless defined $line;

        # The file may still be being written; a corrupt/partial record must not
        # abort the poll. Surface it as a diagnostic event and carry on.
        my $rec = eval { decode_json($line) };
        my $err = $@;
        unless ($rec) {
            push @out => $self->_wrap({info => [{tag => 'INTERNAL', debug => 1, important => 1, details => "Failed to decode events record: $err"}]});
            next;
        }

        my $fd = $rec->{facet_data} or next;

        push @out => $self->_wrap($fd);

        # Synthesize harness facets the renderer/rollup expect.
        if (my $fs = $fd->{harness_final_state}) {
            $self->{+FINAL_STATE} = $fs;
            push @out => $self->_wrap({harness_job_end => $self->_job_end_facet($fs)});
        }

        if (my $px = $fd->{harness_process_exit}) {
            push @out => $self->_wrap({harness_job_exit => $self->_job_exit_facet($px)});
            # TODO(Task 4): retry intent is not represented in the events file
            # yet; the collector model must thread retry through the gatherer
            # (the gatherer keys on done->{retry} to keep a job PENDING).
            $self->{+DONE} = {retry => 0};
        }
    }

    return @out;
}

sub _wrap {
    my $self = shift;
    my ($fd) = @_;

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

sub _stamp_for {
    my $self = shift;
    my ($fd) = @_;
    for my $f (qw/harness_process_exit harness_final_state harness_state_transition/) {
        return $self->{+LAST_STAMP} = $fd->{$f}{stamp} if $fd->{$f} && defined $fd->{$f}{stamp};
    }
    return $self->{+LAST_STAMP} = $fd->{trace}{stamp} if $fd->{trace} && defined $fd->{trace}{stamp};
    return $self->{+LAST_STAMP};
}

sub _job_exit_facet {
    my $self = shift;
    my ($px) = @_;
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

sub _job_end_facet {
    my $self = shift;
    my ($fs) = @_;
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
        stamp    => $fs->{stamp},
        times    => $fs->{times},
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::JobReader - Tail a Test2-Collector events.jsonl.zst
file and emit wrapped harness events.

=head1 DESCRIPTION

Reads a C<.jsonl.zst> file produced by L<Test2::Collector::Recorder::Zstd> and
turns each record into a L<Test2::Harness2::Event>, synthesizing the
C<harness_job_exit> and C<harness_job_end> facets that the renderer and rollup
expect. This replaces the old JobDir approach of scraping stdout/stderr/exit
files and parsing TAP.

=head1 SYNOPSIS

    my $reader = Test2::Harness2::Collector::JobReader->new(
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

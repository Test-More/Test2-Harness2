package Test2::Harness2::Event;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/confess/;
use Time::HiRes qw/time/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::HashBase qw{
    <facet_data
    <stream_id
    <event_id
    <run_id
    <job_id
    <job_try
    <stamp
    +json
    processed
};

sub init {
    my $self = shift;

    my $data = $self->{+FACET_DATA}
        or confess "'facet_data' is a required attribute";

    $self->{+JOB_ID}   //= 0;
    $self->{+EVENT_ID} //= $data->{harness}{+EVENT_ID} // gen_uuid();
    $self->{+STAMP}    //= $data->{harness}{+STAMP}    // time();

    # Populate harness facet with event metadata
    $data->{harness} //= {};
    $data->{harness}{+EVENT_ID} = $self->{+EVENT_ID};
    $data->{harness}{+STAMP}    = $self->{+STAMP};

    for my $field (RUN_ID(), JOB_ID(), JOB_TRY()) {
        next if $field eq +JOB_TRY && !defined($self->{+JOB_TRY}) && !$self->{+JOB_ID};

        my $self_val    = $self->{$field};
        my $harness_val = $data->{harness}{$field};

        if (defined($self_val) && defined($harness_val) && $self_val ne $harness_val) {
            confess "'$field' has different values between attribute and facet data: '$self_val' vs '$harness_val'";
        }

        $self->{$field} = $data->{harness}{$field} = $self_val // $harness_val;
    }

    # Clean up any accidental self-reference
    delete $data->{facet_data};
}

sub as_json { $_[0]->{+JSON} //= encode_json($_[0]) }

sub TO_JSON {
    my $out = {%{$_[0]}};

    $out->{+FACET_DATA} = {%{$out->{+FACET_DATA}}};
    delete $out->{+FACET_DATA}->{harness_job_watcher};
    delete $out->{+FACET_DATA}->{harness}->{closed_by} if $out->{+FACET_DATA}->{harness};
    delete $out->{+JSON};
    delete $out->{+PROCESSED};

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Event - Event class used by Test2::Harness2.

=head1 DESCRIPTION

Represents a single event in the test harness pipeline. Events carry
C<facet_data> which describes what happened (assertions, output, etc.) along
with harness metadata such as C<run_id>, C<job_id>, and C<event_id>.

=head1 SYNOPSIS

    use Test2::Harness2::Event;

    my $event = Test2::Harness2::Event->new(
        facet_data => { assert => { pass => 1, details => 'ok 1' } },
        run_id     => $run_id,
        job_id     => $job_id,
        job_try    => 0,
    );

    my $json = $event->as_json();

=head1 ATTRIBUTES

=over 4

=item facet_data

HashRef of Test2 facet data. Required.

=item event_id

UUID for this event. Auto-generated if not provided.

=item run_id

The run UUID.

=item job_id

The job UUID.

=item job_try

Integer attempt counter (0-based).

=item stamp

Unix high-resolution timestamp. Auto-set if not provided.

=item stream_id

Internal stream identifier (do not rely on this).

=item processed

Boolean flag set by the harness after processing. Not serialized.

=back

=head1 METHODS

=over 4

=item $json_string = $event->as_json()

Return (and cache) a JSON representation of the event. Fields C<json> and
C<processed> are excluded from the output.

=item $hashref = $event->TO_JSON()

Return a plain hash suitable for JSON serialization, excluding internal fields.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

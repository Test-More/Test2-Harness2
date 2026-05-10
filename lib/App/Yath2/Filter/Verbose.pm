package App::Yath2::Filter::Verbose;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Filter';

# Pass events that carry displayable content; drop pure housekeeping events.
# An event is considered displayable if it has at least one of: assert, info,
# errors, plan, or a harness lifecycle facet (job/run summary).
sub filter_event {
    my ($self, $event) = @_;

    my $fd = $event->{facet_data} or return undef;

    return $event if $fd->{assert};
    return $event if $fd->{info}   && @{$fd->{info}};
    return $event if $fd->{errors} && @{$fd->{errors}};
    return $event if $fd->{plan};

    return $event if $fd->{harness_job_end};
    return $event if $fd->{harness_job_start};
    return $event if $fd->{harness_job_queued};
    return $event if $fd->{harness_run_end};

    return undef;
}

1;

__END__

=head1 NAME

App::Yath2::Filter::Verbose - Pass events with displayable content

=head1 DESCRIPTION

Passes events that carry at least one user-visible facet: assertions,
diagnostics (info), errors, the test plan, or job/run summary facets.
Drops framework-internal housekeeping events that produce no output.

=cut

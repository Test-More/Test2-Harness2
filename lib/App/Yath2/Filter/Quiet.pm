package App::Yath2::Filter::Quiet;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'App::Yath2::Filter';

# Pass only job-level and run-level summary events; drop everything else.
# In quiet mode the user sees one line per job (pass/fail) and a final
# run summary, nothing more.
sub filter_event {
    my ($self, $event) = @_;

    my $fd = $event->{facet_data} // {};
    return $event if $fd->{harness_job_end};
    return $event if $fd->{harness_run_end};

    return undef;
}

1;

__END__

=head1 NAME

App::Yath2::Filter::Quiet - Pass only job and run summary events

=head1 DESCRIPTION

Passes only C<harness_job_end> and C<harness_run_end> harness lifecycle
events. All other events (individual assertions, diagnostics, plan, etc.)
are dropped. Suitable for quiet output modes where the user only wants
to know which jobs passed and which failed.

=cut

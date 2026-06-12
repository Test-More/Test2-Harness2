package App::Yath2::Options::Collector;
use v5.38;

our $VERSION = '2.000000';

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Collector - collector options for Yath.

=head1 DESCRIPTION

This is where the command line options for the collector are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

=cut

option_group {group => 'collector', category => "Collector Options"} => sub {
    option max_open_jobs => (
        type           => 'Scalar',
        long_examples  => [' 18'],
        short_examples => [' 18'],
        description    => 'Maximum number of jobs a collector can process at a time, if more jobs are pending their output will be delayed until the earlier jobs have been processed. (Default: double the -j value)',
    );

    option max_poll_events => (
        type           => 'Scalar',
        default        => 1000,
        long_examples  => [' 1000'],
        short_examples => [' 1000'],
        description    => 'Maximum number of events to poll from a job before jumping to the next job. (Default: 1000)',
    );
};

option_post_process 0 => sub ($options, $state) {
    my $settings = $state->{settings};

    unless ($settings->collector->max_open_jobs) {
        my $j = $settings->check_group('runner') ? ($settings->runner->job_count // 1) : 1;
        my $max_open = 2 * $j;
        $settings->collector->create_option(max_open_jobs => $max_open);
    }
};

1;

__END__

=pod

=encoding UTF-8

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

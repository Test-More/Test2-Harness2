package App::Yath2::Renderer;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use parent 'Test2::Harness2::Renderer';
use Test2::Harness2::Util::HashBase qw{
    <color
    <hide_runner_output
    <progress
    <quiet
    <show_times
    <term_width
    <truncate_runner_output
    <verbose
    <wrap
    <interactive
    <is_persistent
    <show_job_end
    <show_job_info
    <show_job_launch
    <show_run_info
    <show_run_fields
    <settings
    <theme
};

sub args_from_settings {
    my ($class, $settings) = @_;

    croak "'settings' is required" unless $settings;

    my %args = (settings => $settings);

    # Pull common renderer options from settings if available
    for my $attr (
        qw/color verbose quiet show_times term_width wrap interactive
                     is_persistent show_job_end show_job_info show_job_launch
                     show_run_info show_run_fields hide_runner_output
                     truncate_runner_output progress theme/
        )
    {
        my $val;
        if ($settings->can($attr)) {
            $val = $settings->$attr;
        }
        elsif (ref($settings) eq 'HASH') {
            $val = $settings->{$attr};
        }
        $args{$attr} = $val if defined $val;
    }

    return %args;
}

sub init { }

sub weight { 0 }

sub render_event { croak "$_[0] forgot to override 'render_event()'" }

sub step          { }
sub signal        { }
sub exit_hook     { }
sub end_of_events { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer - Base class for App::Yath2 renderers.

=head1 DESCRIPTION

Extends L<Test2::Harness2::Renderer> with common attributes and helpers for
yath-specific rendering.

=head1 METHODS

=over 4

=item %args = $class->args_from_settings($settings)

Build constructor arguments from a settings object or hashref.

=item $n = $renderer->weight()

Returns 0. Override in subclasses to control renderer ordering.

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

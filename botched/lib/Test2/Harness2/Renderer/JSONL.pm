package Test2::Harness2::Renderer::JSONL;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/confess/;

use Test2::Harness2::Util::JSON qw/encode_json/;

use base 'Test2::Harness2::Renderer';
use Test2::Harness2::Util::HashBase qw{
    log_file
    fh
};

sub produces_terminal_output { 0 }

sub start {
    my $self = shift;
    my %args = @_;

    my $file = $args{log_file} // $self->{+LOG_FILE}
        or confess "No log_file provided to start()";

    open(my $fh, '>', $file)
        or confess "Cannot open log file '$file' for writing: $!";

    $fh->autoflush(1);

    $self->{+FH} = $fh;
}

sub render_event {
    my ($self, $event) = @_;

    my $fh = $self->{+FH}
        or confess "render_event called before start()";

    my $json = $event->can('as_json') ? $event->as_json() : encode_json($event);

    print $fh $json, "\n";
}

sub finish {
    my $self = shift;

    my $fh = delete $self->{+FH};
    close($fh) if $fh;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Renderer::JSONL - Write test events as JSONL.

=head1 DESCRIPTION

A renderer that writes each event as a single JSON line (JSONL format) to a
log file. This renderer is always present in the watcher — it writes the
test's event log. Additional renderers can be added alongside it.

=head1 ATTRIBUTES

=over 4

=item log_file

Path to the output JSONL log file.

=item fh

The open file handle (set by C<start()>, cleared by C<finish()>).

=back

=head1 METHODS

=over 4

=item $renderer->start(%args)

Opens the log file for writing with autoflush enabled. Accepts an optional
C<log_file> argument to override the C<log_file> attribute.

=item $renderer->render_event($event)

Writes the event as a JSON line. Uses C<< $event->as_json() >> if available,
otherwise falls back to C<encode_json($event)>.

=item $renderer->finish(%args)

Closes the log file handle.

=item $bool = $renderer->produces_terminal_output()

Returns false (0).

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

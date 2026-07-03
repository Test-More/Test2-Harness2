package Test2::Harness2::Util::Directives::Base;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Directives::Base - Shared line-driver for the directive parsers.

=head1 DESCRIPTION

Common base class for L<Test2::Harness2::Util::Directives> (the C<HARNESS2:>
grammar parser) and L<Test2::Harness2::Util::Directives::Legacy> (the 1.0
C<HARNESS-…> compat parser). It owns the file / filehandle / string drivers, the
per-line preamble (line-number tracking + embedded-newline guard), and the
empty-subtree pruning shared by both parsers.

Each subclass supplies its own C<new> and C<finish>, plus a C<_parse_line> hook
that interprets one already-guarded line.

=head1 METHODS

=over 4

=item $result = $invocant->parse_file($path, %ctor_args)

=item $result = $invocant->parse_fh($fh, %ctor_args)

=item $result = $invocant->parse_string($text, %ctor_args)

Class or instance methods. Feed a file / filehandle / string through the parser
and return the C<finish> result. As a class method a fresh parser is constructed
from C<%ctor_args> first.

=item $invocant->parse_line($line)

Track the line number, croak on an embedded newline, then hand the line to the
subclass C<_parse_line> interpreter.

=item $self->_prune($node)

Recursively drop empty subtrees and empty leaf arrays from the result.

=back

=cut

sub parse_file ($invocant, $path, %args) {
    open my $fh, '<', $path or croak "open '$path': $!";
    my $h = $invocant->parse_fh($fh, %args);
    close $fh;
    return $h;
}

sub parse_fh ($invocant, $fh, %args) {
    my $self = ref($invocant) ? $invocant : $invocant->new(%args);
    while (defined(my $line = <$fh>)) {
        $line =~ s/\r?\n\z//;
        $self->parse_line($line);
    }
    return $self->finish;
}

sub parse_string ($invocant, $text, %args) {
    my $self = ref($invocant) ? $invocant : $invocant->new(%args);
    for my $line (split /\r?\n/, $text, -1) {
        $self->parse_line($line);
    }
    return $self->finish;
}

sub parse_line ($self, $line) {
    $self->{line_no}++;

    croak "parse_line: embedded newline at line $self->{line_no}"
        if defined($line) && $line =~ /\n/;

    return unless defined $line;

    return $self->_parse_line($line);
}

sub _prune ($self, $node) {
    for my $k (keys %$node) {
        my $v = $node->{$k};
        if (ref($v) eq 'HASH') {
            $self->_prune($v);
            delete $node->{$k} unless keys %$v;
        }
        elsif (ref($v) eq 'ARRAY') {
            delete $node->{$k} unless @$v;
        }
    }

    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

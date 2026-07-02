package Test2::Harness2::Util::File::Value;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Util::File';
use Test2::Harness2::Util::HashBase;

sub init {
    my $self = shift;

    # Chain to the base initializer so the required-name croak and the
    # fh-constructor-arg (-> _INIT_FH) handling still run.
    $self->SUPER::init();

    # DONE=1 is deliberate: a value file is complete at read time, so a final
    # value with no trailing newline must be surfaced rather than held back.
    $self->{+DONE} = 1;
}

sub reset {
    my $self = shift;

    # SUPER::reset() clears DONE (it re-arms the partial-line hold for a
    # re-read); for a value file DONE must stay set so a newline-less value is
    # still surfaced after a reset.
    $self->SUPER::reset();
    $self->{+DONE} = 1;
    return;
}

sub read {
    my $self = shift;
    my $out = $self->SUPER::read(@_);
    chomp($out) if defined $out;
    return $out;
}

sub read_line {
    my $self = shift;
    my $out = $self->SUPER::read_line(@_);
    chomp($out) if defined $out;
    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File::Value - Utility class for a file that contains
exactly 1 value.

=head1 DESCRIPTION

This is a subclass of L<Test2::Harness2::Util::File> for files expected to have
exactly 1 value stored in them.

=head1 SYNOPSIS

    use Test2::Harness2::Util::File::Value;

    my $vf = Test2::Harness2::Util::File::Value->new(name => 'path/to/file');
    my $val = $vf->read;

=head1 METHODS

=over 4

=item $val = $vf->read()

Read all contents from the file, C<chomp()> it, and return it.

=item $val = $vf->read_line()

Read the first line from the file, C<chomp()> it, and return it. Note, this
may not return anything if the value in the file does not terminate with a
newline.

=back

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

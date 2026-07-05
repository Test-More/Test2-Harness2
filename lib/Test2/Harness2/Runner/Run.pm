package Test2::Harness2::Runner::Run;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();

use parent 'Test2::Harness2::Run';
use Test2::Harness2::Util::HashBase qw{
    <workdir

    +run_dir

    <raw_item
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'workdir' is a required attribute" unless $self->{+WORKDIR};
}

sub run_dir { $_[0]->{+RUN_DIR} //= $_[0]->SUPER::run_dir($_[0]->{+WORKDIR}) }

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Run - Runner specific subclass of a test run.

=head1 DESCRIPTION

Runner subclass of L<Test2::Harness2::Run> for use inside the runner.

=head1 METHODS

In addition to the methods provided by L<Test2::Harness2::Run>, these are provided.

=over 4

=item $dir = $run->workdir

Runner directory.

=item $dir = $run->run_dir

Directory specific to this run.

=item $hashref = $run->raw_item

The raw queued run item (the hash the queuing client sent) stored verbatim on the
run object, so the runner can forward it to a stage service on dispatch. Pruned
automatically when the run object is dropped.

=back

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

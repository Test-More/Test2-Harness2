package Test2::Harness2::Run;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Run::Job;

use Object::HashBase qw{
    <run_uuid
    <jobs
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run - Complete, final spec for one test run.

=head1 DESCRIPTION

A run is a UUID plus an ordered list of L<Test2::Harness2::Run::Job>
objects. Like the jobs it carries, a run is a value object in its B<final>
form: it does no discovery or sniffing. A producer (such as an
L<App::Yath2> subclass) populates everything before the run is serialized
to the harness, and the harness rehydrates plain C<Test2::Harness2::Run> /
C<Test2::Harness2::Run::Job> objects from the data.

Runs serialize via C<TO_JSON> and rehydrate via C<new> on the decoded
hash; job entries that arrive as plain hashrefs are re-blessed into
L<Test2::Harness2::Run::Job> automatically.

=head1 SYNOPSIS

    use Test2::Harness2::Run;

    my $run = Test2::Harness2::Run->new(
        jobs => [
            {test_file => 't/foo.t', includes => ['lib']},
            {test_file => 't/bar.t', includes => ['lib']},
        ],
    );

=head1 ATTRIBUTES

=over 4

=item run_uuid

UUID identifying this run. Generated when not supplied.

=item jobs

Arrayref of one or more L<Test2::Harness2::Run::Job> objects (required).
Entries may be given as plain hashrefs, which are passed to
C<< Test2::Harness2::Run::Job->new >>.

=back

=cut

sub init ($self) {
    $self->{+RUN_UUID} //= gen_uuid();

    my $jobs = $self->{+JOBS};
    croak "'jobs' is a required attribute (an arrayref of one or more jobs)"
        unless ref($jobs) eq 'ARRAY' && @$jobs;

    $self->{+JOBS} = [map { $self->_coerce_job($_) } @$jobs];

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $hashref = $run->TO_JSON

Plain hash of every attribute (jobs serialize through their own
C<TO_JSON>). Feeding the decoded hash back to C<new> reproduces the run.

=back

=cut

sub TO_JSON ($self) { return {%$self} }

=head1 PRIVATE METHODS

=over 4

=item $job = $self->_coerce_job($thing)

Accept a L<Test2::Harness2::Run::Job> instance as-is, construct one from a
plain hashref, croak on anything else.

=back

=cut

sub _coerce_job ($self, $thing) {
    if (blessed($thing)) {
        return $thing if $thing->isa('Test2::Harness2::Run::Job');
        croak "'jobs' entries must be Test2::Harness2::Run::Job instances or hashrefs, got a " . ref($thing);
    }

    return Test2::Harness2::Run::Job->new(%$thing) if ref($thing) eq 'HASH';

    croak "'jobs' entries must be Test2::Harness2::Run::Job instances or hashrefs";
}

1;

__END__

=pod

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

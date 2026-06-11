package Test2::Harness2::Run::Job;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase qw{
    <job_uuid
    <try
    <test_file
    <env_vars
    <includes
    <via
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run::Job - Complete, final spec for one test process.

=head1 DESCRIPTION

A job carries everything a collector needs to run one test: the test file,
the environment variables to set, the include paths to add, and the launch
method. It is a value object in its B<final> form -- it does no file
sniffing, no directive scanning, and no discovery of any kind. A producer
(such as an L<App::Yath2> subclass) is responsible for populating the
attribute values before the job is serialized to the harness; the harness
rehydrates plain C<Test2::Harness2::Run::Job> objects from that data.

Jobs serialize via C<TO_JSON> and rehydrate via C<new> on the decoded hash.

=head1 SYNOPSIS

    use Test2::Harness2::Run::Job;

    my $job = Test2::Harness2::Run::Job->new(
        test_file => 't/foo.t',
        env_vars  => {FOO => 1},
        includes  => ['lib'],
    );

=head1 ATTRIBUTES

=over 4

=item job_uuid

UUID identifying this job. Generated when not supplied.

=item try

Attempt number for this job, starting at C<1> (the default). Retry is not
implemented yet, so this is always C<1> for now.

=item test_file

Path to the test file to run (required).

=item env_vars

Hashref of environment variables to set in the test process. Defaults to
an empty hash.

=item includes

Arrayref of include paths added to the test's C<@INC> (as C<-I> flags for
the C<fork_exec> launch method). Defaults to an empty array.

=item via

Launch method. Only C<fork_exec> (fork, then exec a fresh perl) is
supported so far, and it is the default.

=back

=cut

sub init ($self) {
    croak "'test_file' is a required attribute"
        unless defined $self->{+TEST_FILE} && length $self->{+TEST_FILE};

    $self->{+JOB_UUID} //= gen_uuid();
    $self->{+TRY}      //= 1;
    $self->{+ENV_VARS} //= {};
    $self->{+INCLUDES} //= [];
    $self->{+VIA}      //= 'fork_exec';

    croak "'env_vars' must be a hashref"   unless ref($self->{+ENV_VARS}) eq 'HASH';
    croak "'includes' must be an arrayref" unless ref($self->{+INCLUDES}) eq 'ARRAY';

    croak "'$self->{+VIA}' is not a supported 'via' (only 'fork_exec' is implemented)"
        unless $self->{+VIA} eq 'fork_exec';

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $hashref = $job->TO_JSON

Plain hash of every attribute, suitable for JSON serialization. Feeding
the decoded hash back to C<new> reproduces the job.

=back

=cut

sub TO_JSON ($self) { return {%$self} }

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

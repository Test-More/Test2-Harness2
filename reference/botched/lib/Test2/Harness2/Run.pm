package Test2::Harness2::Run;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Test2::Harness2::Run::Job;

use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::HashBase qw{
    <uuid
    <test_files
    <test_settings
    <jobs
    <status
    <renderers
};

sub init {
    my $self = shift;

    $self->{+UUID}   = gen_uuid();
    $self->{+STATUS} = 'pending';

    $self->{+TEST_FILES} //= [];
    $self->{+JOBS} = [];

    if (@{$self->{+TEST_FILES}}) {
        for my $tf (@{$self->{+TEST_FILES}}) {
            push @{$self->{+JOBS}}, Test2::Harness2::Run::Job->new(
                test_file => $tf,
                run_id    => $self->{+UUID},
            );
        }
    }

    return;
}

sub add_test_files {
    my ($self, $test_files) = @_;

    for my $tf (@{$test_files}) {
        push @{$self->{+TEST_FILES}}, $tf;
        push @{$self->{+JOBS}}, Test2::Harness2::Run::Job->new(
            test_file => $tf,
            run_id    => $self->{+UUID},
        );
    }

    return;
}

sub pending_jobs {
    my $self = shift;
    return [grep { $_->status eq 'pending' } @{$self->{+JOBS}}];
}

sub running_jobs {
    my $self = shift;
    return [grep { $_->status eq 'running' } @{$self->{+JOBS}}];
}

sub complete_jobs {
    my $self = shift;
    return [grep { $_->status eq 'complete' } @{$self->{+JOBS}}];
}

sub is_complete {
    my $self = shift;
    return 0 unless @{$self->{+JOBS}};
    return !grep { $_->status ne 'complete' } @{$self->{+JOBS}};
}

sub passed {
    my $self = shift;
    return 0 unless $self->is_complete;
    return !grep { !$_->passed } @{$self->{+JOBS}};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run - Represents a set of tests to run, with job state tracking

=head1 SYNOPSIS

    use Test2::Harness2::Run;

    my $run = Test2::Harness2::Run->new(
        test_files    => \@test_file_objects,
        test_settings => $settings,
    );

    # uuid auto-generated; status starts as 'pending'
    my $uuid = $run->uuid;

    # Access jobs (one per test file)
    my $jobs    = $run->jobs;
    my $pending = $run->pending_jobs;
    my $running = $run->running_jobs;
    my $done    = $run->complete_jobs;

    # Add more test files after construction
    $run->add_test_files(\@more_files);

    # Check overall completion/pass state
    if ($run->is_complete) {
        print $run->passed ? "All passed\n" : "Some failed\n";
    }

=head1 DESCRIPTION

Encapsulates a set of test files to be executed as a single run. On
construction each test file is wrapped in a L<Test2::Harness2::Run::Job>
object. Additional files can be added later via C<add_test_files>.

=head1 ATTRIBUTES

=over 4

=item uuid

Auto-generated UUID string identifying this run.

=item test_files

Arrayref of L<Test2::Harness2::TestFile> objects provided at construction.

=item test_settings

Optional L<Test2::Harness2::TestSettings> object shared across all jobs in
this run.

=item jobs

Arrayref of L<Test2::Harness2::Run::Job> objects, one per test file.

=item status

Lifecycle status of the run: C<pending>, C<running>, or C<complete>.

=item renderers

Optional arrayref of renderer objects attached to this run.

=back

=head1 METHODS

=over 4

=item $run = Test2::Harness2::Run->new(%params)

Constructor. C<uuid> is auto-generated. C<status> is set to C<'pending'>.
A L<Test2::Harness2::Run::Job> is created for each element of C<test_files>.

=item $run->add_test_files(\@test_files)

Append additional test files to the run. New L<Test2::Harness2::Run::Job>
objects are created and appended to the C<jobs> list.

=item $run->pending_jobs()

Returns an arrayref of jobs whose status is C<'pending'>.

=item $run->running_jobs()

Returns an arrayref of jobs whose status is C<'running'>.

=item $run->complete_jobs()

Returns an arrayref of jobs whose status is C<'complete'>.

=item $run->is_complete()

Returns true when every job has status C<'complete'> (and the run has at least
one job).

=item $run->passed()

Returns true when C<is_complete> is true and every job has passed.

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

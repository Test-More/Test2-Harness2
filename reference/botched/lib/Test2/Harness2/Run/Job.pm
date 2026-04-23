package Test2::Harness2::Run::Job;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/confess/;

use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::HashBase qw{
    <test_file
    <run_id
    <uuid
    <status
    <try_num
    +passed
    +exit_code
    +log_file
    +_previous_uuids
};

# Readers for '+' attributes (key constant only, no auto-generated reader)
sub passed    { $_[0]->{+PASSED} }
sub exit_code { $_[0]->{+EXIT_CODE} }
sub log_file  { $_[0]->{+LOG_FILE} }

sub init {
    my $self = shift;

    $self->{+UUID}            = gen_uuid();
    $self->{+STATUS}          = 'pending';
    $self->{+TRY_NUM}         = 0;
    $self->{+_PREVIOUS_UUIDS} = [];

    return;
}

sub set_status {
    my ($self, $status) = @_;
    $self->{+STATUS} = $status;
    return;
}

sub set_result {
    my ($self, %params) = @_;
    $self->{+PASSED}    = $params{passed};
    $self->{+EXIT_CODE} = $params{exit_code};
    return;
}

sub set_log_file {
    my ($self, $path) = @_;
    $self->{+LOG_FILE} = $path;
    return;
}

sub retry {
    my $self = shift;

    push @{$self->{+_PREVIOUS_UUIDS}}, $self->{+UUID};

    $self->{+UUID}      = gen_uuid();
    $self->{+TRY_NUM}   = $self->{+TRY_NUM} + 1;
    $self->{+STATUS}    = 'pending';
    $self->{+PASSED}    = undef;
    $self->{+EXIT_CODE} = undef;
    $self->{+LOG_FILE}  = undef;

    return;
}

sub previous_uuids {
    my $self = shift;
    return $self->{+_PREVIOUS_UUIDS};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run::Job - Individual test job state with retry support

=head1 SYNOPSIS

    use Test2::Harness2::Run::Job;

    my $job = Test2::Harness2::Run::Job->new(
        test_file => $test_file_obj,
        run_id    => 'some-run-uuid',
    );

    # UUID auto-generated; status starts as 'pending'; try_num starts at 0
    my $uuid = $job->uuid;

    $job->set_status('running');
    $job->set_result(passed => 1, exit_code => 0);
    $job->set_log_file('/path/to/log.jsonl');

    # Retry: saves current uuid, generates new one, increments try_num
    $job->retry();
    my $prev = $job->previous_uuids;   # arrayref of prior attempt UUIDs

=head1 DESCRIPTION

Represents a single test execution attempt. Tracks which test file is being
run, the run it belongs to, its current lifecycle status, result, and log file
path. Supports multiple retry attempts via C<retry()>, which archives the
current UUID and resets state for a fresh attempt.

=head1 ATTRIBUTES

=over 4

=item test_file

A L<Test2::Harness2::TestFile> object representing the test being run.

=item run_id

String identifying the parent run.

=item uuid

Auto-generated UUID string identifying this execution attempt.

=item status

Current lifecycle status: C<pending>, C<running>, or C<complete>.

=item try_num

Zero-based integer indicating how many retries have occurred.

=item passed

Boolean result of the test execution. Undef until C<set_result> is called.

=item exit_code

Exit code of the test process. Undef until C<set_result> is called.

=item log_file

Path to the JSONL log file for this attempt. Undef until C<set_log_file> is called.

=back

=head1 METHODS

=over 4

=item $job = Test2::Harness2::Run::Job->new(%params)

Constructor. C<uuid>, C<status>, C<try_num>, and C<_previous_uuids> are
auto-initialized by C<init()>.

=item $job->init()

Auto-generates C<uuid>, sets C<status> to C<'pending'>, C<try_num> to C<0>,
and C<_previous_uuids> to an empty arrayref.

=item $job->set_status($status)

Updates the job's C<status>.

=item $job->set_result(passed => $bool, exit_code => $code)

Stores the result of the test execution.

=item $job->set_log_file($path)

Stores the path to this attempt's log file.

=item $job->retry()

Pushes the current C<uuid> onto the C<_previous_uuids> list, generates a new
UUID, increments C<try_num>, resets C<status> to C<'pending'>, and clears
C<passed>, C<exit_code>, and C<log_file>.

=item $job->previous_uuids()

Returns the arrayref of UUIDs from all previous attempts.

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

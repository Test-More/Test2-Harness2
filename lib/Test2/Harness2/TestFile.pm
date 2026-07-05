package Test2::Harness2::TestFile;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Util::HashBase qw{
    <task_data
};

# Fields of the task payload exposed as read-only accessors. These are the
# already-computed, file-free decisions a test carries from the command-side
# reader (App::Yath2::TestFile) into the runner. Reading any of them never
# touches the test file on disk.
my @FIELDS = qw{
    file rel_file
    job_id job_name run_id
    stage no_preload require_preload preload_list
    category duration rank
    conflicts switches test_args env_vars input
    min_slots max_slots
    use_fork use_preload use_timeout
    smoke io_events binary non_perl
    retry retry_isolated
    event_timeout post_exit_timeout
    job_class stamp
};

{
    no strict 'refs';
    for my $field (@FIELDS) {
        next if __PACKAGE__->can($field);
        *{__PACKAGE__ . "::$field"} = sub { $_[0]->{+TASK_DATA}->{$field} };
    }
}

sub init ($self) {
    my $task = $self->{+TASK_DATA}
        or croak "'task_data' is a required attribute";

    croak "task_data must be a hashref"
        unless ref($task) eq 'HASH';

    croak "task_data is missing a 'file'"
        unless defined $task->{file};
}

sub from_task ($class, $task = undef) {
    croak "from_task requires a task hashref"
        unless $task && ref($task) eq 'HASH';

    return $class->new(task_data => {%$task});
}

sub field ($self, $key) {
    return $self->{+TASK_DATA}->{$key};
}

sub TO_JSON ($self) { return {%{$self->{+TASK_DATA}}} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::TestFile - State-only representation of a queued test.

=head1 DESCRIPTION

This is the runner-side, file-free representation of a test that has already
been discovered, scanned, and turned into a task payload by the command-side
reader L<App::Yath2::TestFile>. It carries the pre-computed per-file state
(category, duration, stage, slots, feature flags, switches, etc.) and never
reads or scans the test file itself.

Reading test files to decide how they run is a user-interface / input concern
and lives in L<App::Yath2::TestFile> (with L<App::Yath2::Finder> for
gathering). The runner consumes only the task payload this object wraps, so it
plans and dispatches a run without parsing any test file.

=head1 SYNOPSIS

    use Test2::Harness2::TestFile;

    # $task is the payload produced by App::Yath2::TestFile->queue_item
    my $tf = Test2::Harness2::TestFile->from_task($task);

    my $stage    = $tf->stage;
    my $duration = $tf->duration;
    my $payload  = $tf->task_data;    # the underlying serializable hash

=head1 ATTRIBUTES

=over 4

=item $hashref = $tf->task_data

The underlying task payload hashref (a shallow copy of what was passed in). This
is the serializable form carried over the wire and recorded in queues.

=back

=head1 METHODS

=over 4

=item $tf = Test2::Harness2::TestFile->from_task(\%task)

Build a state object from a task payload hashref (as produced by
L<App::Yath2::TestFile/queue_item>). The payload is shallow-copied.

=item $val = $tf->field($key)

Read an arbitrary key out of the task payload. Useful for keys without a
dedicated accessor.

=item $hashref = $tf->TO_JSON

Serialize back to the task payload (a copy of C<task_data>).

=item $val = $tf->file

=item $val = $tf->rel_file

=item $val = $tf->job_id

=item $val = $tf->job_name

=item $val = $tf->run_id

=item $val = $tf->stage

=item $val = $tf->category

=item $val = $tf->duration

=item $val = $tf->rank

=item $val = $tf->conflicts

=item $val = $tf->switches

=item $val = $tf->test_args

=item $val = $tf->env_vars

=item $val = $tf->input

=item $val = $tf->min_slots

=item $val = $tf->max_slots

=item $val = $tf->use_fork

=item $val = $tf->use_preload

=item $val = $tf->use_timeout

=item $val = $tf->smoke

=item $val = $tf->io_events

=item $val = $tf->binary

=item $val = $tf->non_perl

=item $val = $tf->retry

=item $val = $tf->retry_isolated

=item $val = $tf->event_timeout

=item $val = $tf->post_exit_timeout

=item $val = $tf->job_class

=item $val = $tf->stamp

Read-only accessors for the corresponding pre-computed task-payload fields. None
of them read the test file from disk.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

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

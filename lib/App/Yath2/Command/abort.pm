package App::Yath2::Command::abort;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep/;
use Term::Table;

use File::Spec();

use App::Yath2::Util qw/find_pfile/;

use Test2::Harness2::Runner::State;
use Test2::Harness2::Util::File::JSON();
use Test2::Harness2::Util::Queue();

use Test2::Harness2::Util qw/open_file/;

use parent 'App::Yath2::Command::status';
use Test2::Harness2::Util::HashBase;

sub group { 'persist' }

sub summary { "Abort all currently running or queued tests without killing the runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will kill all running tests and clear the queue, but will not close the runner.
    EOT
}

sub pfile_params { (no_fatal => 1) }

sub run {
    my $self = shift;

    # Get the output from finding the pfile
    $self->pfile_data();

    my $state = Test2::Harness2::Runner::State->new(
        workdir => $self->workdir,
        observe => 1,
    );

    $state->poll;
    print "\nTruncating Queue...\n\n";
    $state->truncate;
    $state->poll;

    my $running = $state->running_tasks;
    for my $task (values %$running) {
        my $pid = $self->get_job_pid($task->{run_id}, $task->{job_id}) // next;
        my $file = $task->{rel_file};
        print "Killing test $pid - $file...\n";
        kill('INT', $pid);
    }

    print "\n";
    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED


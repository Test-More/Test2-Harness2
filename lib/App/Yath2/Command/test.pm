package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use File::Spec();
use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use Test2::Harness2();
use Test2::Harness2::TestFile();
use Test2::Harness2::Resource::JobCount();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::Yath',
);

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 1 }
sub group              { 'test' }
sub summary            { 'Run a list of test files' }

sub description {
    return <<"    EOT";
Minimal test runner. Pass a list of test files; they are executed via a
Test2::Harness2 child service with 16-slot job concurrency. Exits 0 if every
test passed, non-zero otherwise. The pass/fail verdict is retrieved from the
harness service via IPC -- log files are not consulted.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];

    die "No test files supplied.\nUsage: yath test FILE [FILE ...]\n"
        unless @$args;

    my @files;
    for my $file (@$args) {
        die "Not a readable test file: $file\n" unless -f $file && -r _;
        push @files => Test2::Harness2::TestFile->new(file => $file);
    }

    my $workdir = $settings->workspace->workdir;

    my $spawn = Test2::Harness2->spawn(
        workdir   => $workdir,
        resources => [Test2::Harness2::Resource::JobCount->new(slots => 16)],
    );

    my $queued = $spawn->queue_test_run(files => \@files);
    die "Could not queue run: " . ($queued->{error} // '(no error)') . "\n"
        unless $queued->{ok};
    my $run_id = $queued->{run_id};

    # Poll the harness's run_results handler until the run
    # completes. The handler returns state => 'running' while there
    # is still work in the queue and state => 'complete' with the
    # aggregate pass verdict once run_state_update has observed the
    # final mutation.
    my $final;
    while (1) {
        my $resp = $spawn->run_results(run_id => $run_id);
        die "run_results rejected: " . ($resp->{error} // '(no error)') . "\n"
            unless $resp->{ok};

        if (($resp->{state} // '') eq 'complete') {
            $final = $resp;
            last;
        }

        sleep(0.05);
    }

    $spawn->finish;
    $spawn->wait;

    $settings->workspace->create_option(keep_dirs => 1);

    print "Work directory: $workdir\n";

    return $final->{pass} ? 0 : 1;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

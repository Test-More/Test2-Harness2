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
Test2::Harness2 child service with 16-slot job concurrency, JSON and JSONL
loggers, and no cleanup of the work directory. Exits 0 if every test passed,
non-zero otherwise.
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
    my $logdir  = File::Spec->catdir($workdir, 'logs');

    my $harness_log = File::Spec->catfile($workdir, 'harness.jsonl');

    my $spawn = Test2::Harness2->spawn(
        workdir   => $workdir,
        resources => [Test2::Harness2::Resource::JobCount->new(slots => 16)],
        loggers   => [
            ['Test2::Harness2::Collector::Logger::JSONL', output_file => $harness_log],
        ],
        test_loggers => [
            ['Test2::Harness2::Collector::Logger::JSONL', output_file => '%LOG_DIR%/%JOB_TRY%.jsonl'],
            ['Test2::Harness2::Collector::Logger::JSON',  output_file => '%LOG_DIR%/%JOB_TRY%.json'],
        ],
        test_run                 => {files => \@files},
        finish_after_initial_run => 1,
    );

    $spawn->wait;

    my $pass = $self->_aggregate_pass($harness_log);

    $settings->workspace->create_option(keep_dirs => 1);

    print "Work directory: $workdir\n";
    print "Harness log:    $harness_log\n";

    return $pass ? 0 : 1;
}

sub _aggregate_pass {
    my $self = shift;
    my ($harness_log) = @_;

    open(my $fh, '<', $harness_log) or die "Could not open '$harness_log': $!";

    require Test2::Harness2::Util::JSON;
    my $decode = \&Test2::Harness2::Util::JSON::decode_json;

    my $seen_any = 0;
    my $all_pass = 1;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my $ev = $decode->($line);
        next unless ref($ev) eq 'HASH' && ($ev->{kind} // '') eq 'job_completed';
        $seen_any = 1;
        $all_pass = 0 unless $ev->{pass};
    }
    close($fh);

    die "Harness log contained no job_completed events; run produced no results.\n"
        unless $seen_any;

    return $all_pass;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

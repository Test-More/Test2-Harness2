package Test2::Harness2::MiniHarness;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak confess/;
use File::Spec;
use File::Temp qw/tempdir/;
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/time sleep/;
use Atomic::Pipe;
use Test2::Harness2::Event;
use Test2::Harness2::Auditor;
use Test2::Harness2::TapParser;
use Test2::Harness2::Renderer::JSONL;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;
use Test2::Harness2::MiniHarness::Result;

use Test2::Util::UUID qw/gen_uuid/;

sub run {
    my ($class, %params) = @_;

    my $test_file = $params{test_file} or croak "test_file is required";
    croak "test file '$test_file' does not exist" unless -f $test_file;

    my $uuid      = $params{uuid}      // gen_uuid();
    my $log_dir   = $params{log_dir}   // tempdir(CLEANUP => 1);
    my $env       = $params{env}       // {};
    my $switches  = $params{switches}  // [];
    my $includes  = $params{includes}  // [];
    my $renderers = $params{renderers} // [];
    my $preloaded = $params{preloaded} // 0;

    # When preloaded is true, a future enhancement will use fork+goto::file
    # instead of exec, preserving preloaded modules in the child. For now,
    # preloaded mode falls back to the same exec behavior.

    my $log_file = File::Spec->catfile($log_dir, "$uuid.jsonl");

    # Create Atomic::Pipe pair in mixed_data_mode
    my ($reader, $writer) = Atomic::Pipe->pair(mixed_data_mode => 1);

    # Set up JSONL renderer (always present)
    my $jsonl_renderer = Test2::Harness2::Renderer::JSONL->new();

    my @all_renderers = ($jsonl_renderer, @$renderers);

    # Start all renderers
    for my $r (@all_renderers) {
        $r->start(log_file => $log_file, per_test => 1);
    }

    # Fork the child process
    my $pid = fork();
    confess "fork() failed: $!" unless defined $pid;

    if ($pid == 0) {
        # === CHILD PROCESS ===
        $class->_run_child($writer, $reader, $test_file, $env, $switches, $includes);
        # _run_child calls exec and should never return; if it does:
        exit(255);
    }

    # === PARENT (WATCHER) ===
    my $result = $class->_run_watcher(
        reader        => $reader,
        writer        => $writer,
        pid           => $pid,
        uuid          => $uuid,
        log_file      => $log_file,
        all_renderers => \@all_renderers,
    );

    return $result;
}

sub _run_child {
    my ($class, $writer, $reader, $test_file, $env, $switches, $includes) = @_;

    # Close reader (parent's end)
    $reader->close();

    # Redirect STDOUT and STDERR to the pipe writer.
    # This puts the pipe on FDs 1 and 2, so no FD_CLOEXEC
    # manipulation is needed — STDOUT/STDERR survive exec.
    my $writer_fh = $writer->wh;
    open(STDOUT, '>&', $writer_fh) or die "Cannot redirect STDOUT to pipe: $!";
    open(STDERR, '>&', $writer_fh) or die "Cannot redirect STDERR to pipe: $!";

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    # Set env vars
    $ENV{T2_FORMATTER} = 'Stream2';

    for my $key (keys %$env) {
        $ENV{$key} = $env->{$key};
    }

    # Build perl command
    my @cmd = ($^X);
    push @cmd, @$switches;
    push @cmd, map { "-I$_" } @$includes;
    push @cmd, $test_file;

    exec(@cmd)
        or do { print STDERR "exec failed: $!\n"; POSIX::_exit(255) };
}

sub _run_watcher {
    my ($class, %params) = @_;

    my $reader        = $params{reader};
    my $writer        = $params{writer};
    my $pid           = $params{pid};
    my $uuid          = $params{uuid};
    my $log_file      = $params{log_file};
    my $all_renderers = $params{all_renderers};

    # Close writer (child's end)
    $writer->close();

    my $auditor    = Test2::Harness2::Auditor->new();
    my $tap_parser = Test2::Harness2::TapParser->new();

    my $exited;
    my $exit_code;

    # Helper to feed events through auditor and renderers
    my $process_event = sub {
        my ($event) = @_;
        my @events = $auditor->audit($event);
        for my $e (@events) {
            for my $r (@$all_renderers) {
                $r->render_event($e) if $r->has_render_event(ref($r));
            }
        }
    };

    # Read loop
    while (1) {
        my ($type, $data) = $reader->get_line_burst_or_data();

        if (defined $type) {
            if ($type eq 'message' || $type eq 'burst') {
                # Stream2 JSON event
                my $decoded;
                my $ok  = eval { $decoded = decode_json($data); 1 };
                my $err = $@;

                if ($ok && ref($decoded) eq 'HASH') {
                    my $facet_data = $decoded->{facet_data} // $decoded;
                    my $event      = Test2::Harness2::Event->new(
                        facet_data => $facet_data,
                        (defined $decoded->{event_id}  ? (event_id  => $decoded->{event_id})  : ()),
                        (defined $decoded->{stream_id} ? (stream_id => $decoded->{stream_id}) : ()),
                        (defined $decoded->{stamp}     ? (stamp     => $decoded->{stamp})     : ()),
                    );
                    $process_event->($event);
                }
                else {
                    # Failed to decode, treat as a line
                    $class->_process_line($data, $tap_parser, $process_event);
                }
            }
            elsif ($type eq 'line') {
                $class->_process_line($data, $tap_parser, $process_event);
            }
        }
        else {
            # No data ready
            if (defined $exited) {
                # Child already exited and pipe is drained
                last;
            }

            # Check if child has exited (non-blocking)
            my $check = waitpid($pid, WNOHANG);
            if ($check > 0) {
                $exit_code = $?;
                $exited    = 1;
                # Don't break yet -- keep reading until pipe is empty
                next;
            }
            elsif ($check < 0) {
                # Child already reaped somehow
                $exit_code //= -1;
                $exited = 1;
                next;
            }

            # Child still running, brief sleep
            sleep(0.01);
        }
    }

    # If child not yet reaped, do blocking waitpid
    unless (defined $exit_code) {
        waitpid($pid, 0);
        $exit_code = $?;
    }

    # Create harness_job_exit event
    my $exit_event = Test2::Harness2::Event->new(
        facet_data => {
            harness_job_exit => {
                exit  => $exit_code,
                stamp => time(),
            },
        },
    );
    $process_event->($exit_event);

    # Finalize auditor
    my $final_event = $auditor->_finalize();
    if ($final_event) {
        for my $r (@$all_renderers) {
            $r->render_event($final_event) if $r->has_render_event(ref($r));
        }
    }

    # Finish all renderers
    for my $r (@$all_renderers) {
        $r->finish(log_file => $log_file, per_test => 1);
    }

    my $passed = $auditor->pass;

    return Test2::Harness2::MiniHarness::Result->new(
        passed    => $passed ? 1 : 0,
        exit_code => $exit_code,
        uuid      => $uuid,
        log_file  => $log_file,
    );
}

sub _process_line {
    my ($class, $line, $tap_parser, $process_event) = @_;

    # Skip empty lines
    return unless defined $line && length($line);

    # Try TAP parsing
    my $chomp_line = $line;
    chomp $chomp_line;

    my $facet_data = $tap_parser->parse_tap_line($line);

    if ($facet_data) {
        my $event = Test2::Harness2::Event->new(facet_data => $facet_data);
        $process_event->($event);
    }
    else {
        # Non-TAP line: treat as diagnostic info
        my $event = Test2::Harness2::Event->new(
            facet_data => {
                info => [{
                    details => $chomp_line,
                    tag     => 'STDOUT',
                    debug   => 0,
                }],
            },
        );
        $process_event->($event);
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::MiniHarness - Core test executor with exec mode.

=head1 DESCRIPTION

MiniHarness is the core unit of test execution for L<Test2::Harness2>. It
forks a child process, runs a test file under L<Test2::Formatter::Stream2>,
reads events from an L<Atomic::Pipe> in mixed-data mode, parses TAP output
from direct prints, audits everything through L<Test2::Harness2::Auditor>,
logs events via L<Test2::Harness2::Renderer::JSONL>, and returns a
L<Test2::Harness2::MiniHarness::Result>.

=head1 SYNOPSIS

    use Test2::Harness2::MiniHarness;

    my $result = Test2::Harness2::MiniHarness->run(
        test_file => 't/foo.t',
        log_dir   => '/tmp/logs',
        uuid      => 'custom-uuid',
        env       => { FOO => 'bar' },
        switches  => ['-w'],
        includes  => ['lib'],
    );

    print "Passed!\n" if $result->passed;

=head1 CLASS METHODS

=over 4

=item $result = Test2::Harness2::MiniHarness->run(%params)

Run a test file in exec mode. Parameters:

=over 4

=item test_file (required)

Path to the test file to execute.

=item log_dir

Directory for the JSONL log file. A temp directory is used if not given.

=item uuid

UUID for this test run. Auto-generated if not provided.

=item auditor

Auditor class name (default: L<Test2::Harness2::Auditor>).

=item renderers

Arrayref of additional renderer objects.

=item env

Hashref of extra environment variables for the child.

=item switches

Arrayref of perl switches (e.g. C<-w>).

=item includes

Arrayref of include paths (turned into C<-I> flags).

=back

Returns a L<Test2::Harness2::MiniHarness::Result> object.

=back

=head1 Test2::Harness2::MiniHarness::Result

Simple result object returned by C<run()>.

=head2 METHODS

=over 4

=item $bool = $result->passed

True if the test passed.

=item $int = $result->exit_code

Raw wait status of the child process.

=item $str = $result->uuid

The UUID for this test execution.

=item $path = $result->log_file

Path to the JSONL event log.

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

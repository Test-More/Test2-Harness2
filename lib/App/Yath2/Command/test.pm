package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

use Test2::Harness2::Run;
use Test2::Harness2::Event;
use Test2::Harness2::Util::Queue;
use Test2::Harness2::Util::File::JSON;
use Test2::Harness2::IPC;
use Test2::Harness2::Util::IPC qw/USE_P_GROUPS/;

use Test2::Harness2::Runner::State;

use Test2::Harness2::Util::JSON qw/encode_json decode_json JSON/;
use Test2::Harness2::Util qw/mod2file open_file chmod_tmp collector_exit_code runner_events_file/;
use Test2::Util::Table qw/table/;

use POSIX();

use Test2::Harness2::Util::Term qw/USE_ANSI_COLOR/;

use File::Spec;
use Fcntl();

use Time::HiRes qw/sleep time/;
use List::Util qw/sum max min/;
use Carp qw/croak/;

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase qw/
    <runner_pid +ipc +signal

    +run <run_id

    +collector_writer
    +renderer_reader

    +renderers
    +logger
    +last_log

    +tests_seen
    +asserts_seen

    +run_queue
    +tasks_queue
    +state

    <cleanup_subs

    <final_data
/;

include_options(
    'App::Yath2::Options::Debug',
    'App::Yath2::Options::Display',
    'App::Yath2::Options::Finder',
    'App::Yath2::Options::Logging',
    'App::Yath2::Options::PreCommand',
    'App::Yath2::Options::Run',
    'App::Yath2::Options::Runner',
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::Collector',
);

sub MAX_ATTACH() { 1_048_576 }

sub group { ' test' }

sub summary  { "Run tests" }
sub cli_args { '[--] [test files/dirs] [::] [arguments to test scripts] [test_file.t] [test_file2.t="--arg1 --arg2 --param=\'foo bar\'"] [:: --argv-for-all-tests]' }

sub description {
    return <<"    EOT";
This yath command (which is also the default command) will run all the test
files for the current project. If no test files are specified this command will
look for the 't', and 't2' directories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for
you by default (after any -I's). You can specify -l if you just want lib, -b if
you just want the blib paths. If you specify both -l and -b both will be added
in the order you specify (order relative to any -I options will also be
preserved.  If you do not specify they will be added in this order: -I's, lib,
blib/lib, blib/arch. You can also add --no-lib and --no-blib to avoid both.

Any command line argument that is not an option will be treated as a test file
or directory of test files to be run.

If you wish to specify the ARGV for tests you may append them after '::'. This
is mainly useful for Test::Class::Moose and similar tools. EVERY test run will
get the same ARGV.
    EOT
}

sub spawn_args {
    my $self = shift;
    my ($settings) = @_;

    my @out;

    if ($ENV{T2_DEVEL_COVER} && $ENV{T2_COVER_SELF}) {
        push @out => '-MDevel::Cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl';
    }

    my $plugins = $settings->harness->plugins;
    if (@$plugins) {
        push @out => $_->spawn_args($settings) for grep { $_->can('spawn_args') } @$plugins;
    }

    return @out;
}

sub init {
    my $self = shift;
    $self->SUPER::init() if $self->can('SUPER::init');

    $self->{+TESTS_SEEN}   //= 0;
    $self->{+ASSERTS_SEEN} //= 0;

    $self->{+CLEANUP_SUBS} = [];
}

sub _resize_pipe {
    return unless defined &Fcntl::F_SETPIPE_SZ;
    my ($fh) = @_;

    # 1mb if we can
    my $size = 1024 * 1024 * 1;

    # On linux systems lets go for the smaller of the two between 1mb and
    # system max.
    if (-e '/proc/sys/fs/pipe-max-size') {
        open(my $max, '<', '/proc/sys/fs/pipe-max-size');
        chomp(my $val = <$max>);
        close($max);
        $size = min($size, $val);
    }

    fcntl($fh, Fcntl::F_SETPIPE_SZ(), $size);
}

sub collector_writer {
    my $self = shift;
    return $self->{+COLLECTOR_WRITER} if $self->{+COLLECTOR_WRITER};
    pipe($self->{+RENDERER_READER}, $self->{+COLLECTOR_WRITER}) or die "Could not create pipe: $!";
    _resize_pipe($self->{+COLLECTOR_WRITER});
    return $self->{+COLLECTOR_WRITER};
}

sub renderer_reader {
    my $self = shift;
    return $self->{+RENDERER_READER} if $self->{+RENDERER_READER};
    pipe($self->{+RENDERER_READER}, $self->{+COLLECTOR_WRITER}) or die "Could not create pipe: $!";
    _resize_pipe($self->{+COLLECTOR_WRITER});
    return $self->{+RENDERER_READER};
}

sub workdir {
    my $self = shift;
    $self->settings->workspace->workdir;
}

sub ipc {
    my $self = shift;
    return $self->{+IPC} //= Test2::Harness2::IPC->new(
        handlers => {
            INT  => sub { $self->handle_sig(@_) },
            TERM => sub { $self->handle_sig(@_) },
        }
    );
}

sub handle_sig {
    my $self = shift;
    my ($sig) = @_;

    eval { $_->signal($sig) } for grep { $_->can('signal') } @{$self->renderers};

    print STDERR "\nCaught SIG$sig, forwarding signal to child processes...\n";
    $self->ipc->killall($sig);

    if ($self->{+SIGNAL}) {
        print STDERR "\nSecond signal ($self->{+SIGNAL} followed by $sig), exiting now without waiting\n";
        exit 1;
    }

    $self->{+SIGNAL} = $sig;
}

sub monitor_preloads { 0 }

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $plugins  = $self->settings->harness->plugins;

    if ($self->start()) {
        $self->render();
        $self->stop();

        my $final_data = $self->{+FINAL_DATA} or die "Final data never received from collector!\n";
        my $pass       = $self->{+TESTS_SEEN} && $final_data->{pass};
        $self->render_final_data($final_data);
        $self->produce_summary($pass);

        if (@$plugins) {
            my %args = (
                settings     => $settings,
                final_data   => $final_data,
                pass         => $pass ? 1 : 0,
                tests_seen   => $self->{+TESTS_SEEN}   // 0,
                asserts_seen => $self->{+ASSERTS_SEEN} // 0,
            );
            $_->finish(%args) for @$plugins;
        }

        return $pass ? 0 : 1;
    }

    $self->stop();

    return 1;
}

sub DESTROY {
    my $self = shift;

    local ($?, $!, $@, $_);

    my $cleanup = delete $self->{+CLEANUP_SUBS} or return;
    for my $sub (@$cleanup) {
        eval { $sub->(); 1 } or warn $@;
    }
}

sub write_test_info {
    my $self = shift;

    return if $ENV{TEST2_HARNESS_NO_WRITE_TEST_INFO};

    my $info_file = "./.test_info.$$.json";

    my $workdir = $self->workdir;
    Test2::Harness2::Util::File::JSON->new(name => $info_file)->write({
        workdir   => $self->workdir,
        job_count => $self->job_count,
    });

    push @{$self->{+CLEANUP_SUBS}} => sub {
        return unless -e $info_file;
        return unless Test2::Harness2::Util::File::JSON->new(name => $info_file)->read->{workdir} eq $workdir;
        unlink($info_file) or die "Could not unlink info file: $!";
    };

    $ENV{TEST2_HARNESS_NO_WRITE_TEST_INFO} = 1;
}

sub start {
    my $self = shift;

    $self->ipc->start();
    $self->parse_args;
    $self->write_settings_to($self->workdir, 'settings.json');

    $self->write_test_info();
    my $pop = $self->populate_queue();
    $self->terminate_queue();

    return unless $pop;

    $self->setup_plugins();
    $self->setup_resources();

    $self->start_runner(jobs_todo => $pop);
    $self->start_collector();

    return 1;
}

sub render {
    my $self = shift;

    my $ipc       = $self->ipc;
    my $settings  = $self->settings;
    my $renderers = $self->renderers;
    my $logger    = $self->logger;
    my $plugins   = $self->settings->harness->plugins;

    my $handle_plugins   = [grep { $_->can('handle_event') } @$plugins];
    my $annotate_plugins = [grep { $_->can('annotate_event') } @$plugins];

    # render results from log
    my $reader = $self->renderer_reader();
    $reader->blocking(0);
    my $buffer;
    while (1) {
        return if $self->{+SIGNAL};
        $_->step for @{$renderers};

        my $line = <$reader>;
        unless (defined $line) {
            $ipc->wait() if $ipc;
            sleep 0.02;
            next;
        }

        if ($buffer) {
            $line   = $buffer . $line;
            $buffer = undef;
        }

        unless (substr($line, -1, 1) eq "\n") {
            $buffer //= "";
            $buffer .= $line;
            next;
        }

        my $e = decode_json($line);

        if (defined $e) {
            bless($e, 'Test2::Harness2::Event');
            my $fd = $e->{facet_data} //= {};

            my $changed = 0;
            for my $p (@$annotate_plugins) {
                my %inject = $p->annotate_event($e, $settings);
                next unless keys %inject;
                $changed++;

                # Can add new facets, but not modify existing ones.
                # Someone could force the issue by modifying the event directly
                # inside 'annotate_event', this is not supported, but also not
                # forbidden, user beware.
                for my $f (keys %inject) {
                    if (exists $fd->{$f}) {
                        if ('ARRAY' eq ref($fd->{$f})) {
                            push @{$fd->{$f}} => @{$inject{$f}};
                        }
                        else {
                            warn "Plugin '$p' tried to add facet '$f' via 'annotate_event()', but it is already present and not a list, ignoring plugin annotation.\n";
                        }
                    }
                    else {
                        $fd->{$f} = $inject{$f};
                    }
                }

            }

            if ($logger) {
                if ($changed) {
                    my $newline = $e->as_json;
                    print $logger $newline, "\n";
                }
                else {
                    print $logger $line;
                }
            }
        }
        else {
            last;
        }

        if (my $final = $e->{facet_data}->{harness_final}) {
            $self->{+FINAL_DATA} = $final;
        }
        $_->render_event($e) for @$renderers;

        $self->{+TESTS_SEEN}++   if $e->{facet_data}->{harness_job_launch};
        $self->{+ASSERTS_SEEN}++ if $e->{facet_data}->{assert};

        $_->handle_event($e, $settings) for @$handle_plugins;

        $ipc->wait() if $ipc;
    }
}

sub get_job_pid {
    my $self = shift;
    my ($run_id, $job_id) = @_;

    return undef unless $run_id && $job_id;

    my $run_dir   = File::Spec->catdir($self->workdir, $run_id);
    my $jobs_file = File::Spec->catfile($run_dir, 'jobs.jsonl');

    return undef unless -f $jobs_file;
    my $queue = Test2::Harness2::Util::Queue->new(file => $jobs_file);

    my $found;
    for my $item ($queue->poll) {
        my $task = $item->[-1];
        next unless $task->{job_id} && $task->{job_id} eq $job_id;
        $found = $task;
    }

    return undef unless $found;

    return $found->{pid} // undef;
}

sub stop {
    my $self = shift;

    my $settings  = $self->settings;
    my $renderers = $self->renderers;
    my $logger    = $self->logger;

    $self->teardown_plugins($renderers, $logger);
    if ($logger) {
        print $logger "null\n";
        close($logger);
    }

    $_->finish() for @$renderers;

    my $ipc = $self->ipc;
    print STDERR "Waiting for child processes to exit...\n" if $self->{+SIGNAL};

    if ($self->{+SIGNAL}) {
        my $state = $self->state;
        delete $state->{no_poll};
        $state->poll;
        my $running = $state->running_tasks;
        $state->halt_run($self->{+RUN_ID});

        for my $task (values %$running) {
            next unless $task->{run_id} && $task->{run_id} eq $self->{+RUN_ID};
            my $pid  = $self->get_job_pid($task->{run_id}, $task->{job_id}) // next;
            my $file = $task->{rel_file};
            print "Killing test $pid - $file...\n";
            kill('INT', USE_P_GROUPS ? -$pid : $pid);
        }
    }

    $ipc->wait(all => 1);
    $ipc->stop;

    unless ($settings->display->quiet > 2) {
        printf STDERR "\nNo tests were seen!\n" unless $self->{+TESTS_SEEN};

        printf("\nKeeping work dir: %s\n", $self->workdir)
            if $settings->debug->keep_dirs;

        if ($settings->logging->log) {
            print "\n";
            print "Wrote log file: " . $settings->logging->log_file . "\n";
            print " (Symlinked to: " . $self->{+LAST_LOG} . ")\n";
        }

        $self->finalize_plugins();
    }
}

sub terminate_queue {
    my $self = shift;

    $self->tasks_queue->end();
    $self->state->end_queue();
}

sub build_run {
    my $self = shift;

    return $self->{+RUN} if $self->{+RUN};

    my $settings = $self->settings;
    my $dir      = $self->workdir;

    my $run = Test2::Harness2::Run->new($settings->run->all);

    mkdir($run->run_dir($dir)) or die "Could not make run dir: $!";
    chmod_tmp($dir);

    return $self->{+RUN} = $run;
}

sub state {
    my $self = shift;

    $self->{+STATE} //= Test2::Harness2::Runner::State->new(
        workdir   => $self->workdir,
        job_count => $self->job_count,
        no_poll   => 1,
    );
}

sub job_count {
    my $self = shift;

    return $self->settings->runner->job_count;
}

sub run_queue {
    my $self = shift;
    my $dir  = $self->workdir;
    return $self->{+RUN_QUEUE} //= Test2::Harness2::Util::Queue->new(file => File::Spec->catfile($dir, 'run_queue.jsonl'));
}

sub tasks_queue {
    my $self = shift;

    $self->{+TASKS_QUEUE} //= Test2::Harness2::Util::Queue->new(
        file => File::Spec->catfile($self->build_run->run_dir($self->workdir), 'queue.jsonl'),
    );
}

sub finder_args { () }

sub populate_queue {
    my $self = shift;

    my $run = $self->build_run();
    $self->{+RUN_ID} = $run->run_id;
    my $settings     = $self->settings;
    my $finder_class = $settings->finder->finder;
    require(mod2file($finder_class));
    my $finder = $finder_class->new($settings->finder->all, $self->finder_args);

    my $state       = $self->state;
    my $tasks_queue = $self->tasks_queue;
    my $plugins     = $settings->harness->plugins;

    $state->queue_run($run->queue_item($plugins));

    my @files = @{$finder->find_files($plugins, $self->settings)};

    for my $plugin (@$plugins) {
        if ($plugin->can('sort_files_2')) {
            @files = $plugin->sort_files_2(settings => $settings, files => \@files);
        }
        elsif ($plugin->can('sort_files')) {
            @files = $plugin->sort_files(@files);
        }
    }

    my $job_count = 0;
    for my $file (@files) {
        my $task = $file->queue_item(
            ++$job_count, $run->run_id,
            $settings->check_group('display') ? (verbose => $settings->display->verbose) : (),
        );

        $task->{category} = 'isolation' if $settings->debug->interactive;

        $state->queue_task($task);
        $tasks_queue->enqueue($task);
    }

    $state->stop_run($run->run_id);

    return $job_count;
}

sub produce_summary {
    my $self = shift;
    my ($pass) = @_;

    my $settings = $self->settings;

    my $time_data = {
        start => $settings->harness->start,
        stop  => time(),
    };

    $time_data->{wall} = $time_data->{stop} - $time_data->{start};

    my @times = times();
    @{$time_data}{qw/user system cuser csystem/} = @times;
    $time_data->{cpu} = sum @times;

    my $cpu_usage = int($time_data->{cpu} / $time_data->{wall} * 100);

    $self->write_summary($pass, $time_data, $cpu_usage);
    $self->render_summary($pass, $time_data, $cpu_usage);
}

sub write_summary {
    my $self = shift;
    my ($pass, $time_data, $cpu_usage) = @_;

    my $file = $self->settings->debug->summary or return;

    my $final_data = $self->{+FINAL_DATA};

    my $failures = @{$final_data->{failed} // []};

    my %data = (
        %$final_data,

        pass => $pass ? JSON->true : JSON->false,

        total_failures => $failures              // 0,
        total_tests    => $self->{+TESTS_SEEN}   // 0,
        total_asserts  => $self->{+ASSERTS_SEEN} // 0,

        cpu_usage => $cpu_usage,

        times => $time_data,
    );

    require Test2::Harness2::Util::File::JSON;
    my $jfile = Test2::Harness2::Util::File::JSON->new(name => $file);
    $jfile->write(\%data);

    print "\nWrote summary file: $file\n\n";

    return;
}

sub render_summary {
    my $self = shift;
    my ($pass, $time_data, $cpu_usage) = @_;

    return if $self->settings->display->quiet > 1;

    my $final_data = $self->{+FINAL_DATA};
    my $failures   = @{$final_data->{failed} // []};

    my @summary = (
        $failures ? ("     Fail Count: $failures") : (),
        "     File Count: $self->{+TESTS_SEEN}",
        "Assertion Count: $self->{+ASSERTS_SEEN}",
        $time_data
        ? (
            sprintf("      Wall Time: %.2f seconds",                                                       $time_data->{wall}),
            sprintf("       CPU Time: %.2f seconds (usr: %.2fs | sys: %.2fs | cusr: %.2fs | csys: %.2fs)", @{$time_data}{qw/cpu user system cuser csystem/}),
            sprintf("      CPU Usage: %i%%",                                                               $cpu_usage),
            )
        : (),
    );

    my $res = "    -->  Result: " . ($pass ? 'PASSED' : 'FAILED') . "  <--";
    if ($self->settings->display->color && USE_ANSI_COLOR) {
        my $color = $pass ? Term::ANSIColor::color('bold bright_green') : Term::ANSIColor::color('bold bright_red');
        my $reset = Term::ANSIColor::color('reset');
        $res = "$color$res$reset";
    }
    push @summary => $res;

    my $msg    = "Yath Result Summary";
    my $length = max map { length($_) } @summary;
    my $prefix = ($length - length($msg)) / 2;

    print "\n";
    print " " x $prefix;
    print "$msg\n";
    print "-" x $length;
    print "\n";
    print join "\n" => @summary;
    print "\n";
}

sub render_final_data {
    my $self = shift;
    my ($final_data) = @_;

    return if $self->settings->display->quiet > 1;

    return $self->_render_final_data_plainly($final_data)
        if $self->settings->display->no_final_table;

    if (my $rows = $final_data->{retried}) {
        print "\nThe following jobs failed at least once:\n";
        print join "\n" => table(
            header => ['Job ID', 'Times Run', 'Test File', "Succeeded Eventually?"],
            rows   => $rows,
        );
        print "\n";
    }

    if (my $rows = $final_data->{failed}) {
        print "\nThe following jobs failed:\n";
        print join "\n" => table(
            collapse => 1,
            header   => ['Job ID', 'Test File', 'Subtests'],
            rows     => [map { my $r = [@{$_}]; $r->[2] = stringify_subtest_map($r->[2]) if $r->[2]; $r } @$rows],
        );
        print "\n";
    }

    if (my $rows = $final_data->{halted}) {
        print "\nThe following jobs requested all testing be halted:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File', "Reason"],
            rows   => $rows,
        );
        print "\n";
    }

    if (my $rows = $final_data->{unseen}) {
        print "\nThe following jobs never ran:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File'],
            rows   => $rows,
        );
        print "\n";
    }
}

sub _render_final_data_plainly {
    my $self = shift;
    my ($final_data) = @_;

    return if $self->settings->display->quiet > 1;

    if (my $rows = $final_data->{retried}) {
        print "\nThe following jobs failed at least once:\n";
        for my $row (@$rows) {
            print "- filename: $row->[2]\n";
            print "  job_id: $row->[0]\n";
            print "  times_run: $row->[1]\n";
            print "  succeeded_eventually: $row->[3]\n";
        }
    }

    if (my $rows = $final_data->{failed}) {
        print "\nThe following jobs failed:\n";
        for my $row (@$rows) {
            print "- filename: $row->[1]\n";
            print "  job_id: $row->[0]\n";
            if ($row->[2]) {
                print "  subtests:\n";
                my @paths = _subtest_paths($row->[2]);
                print "  - $_\n" for @paths;
            }
        }
    }

    if (my $rows = $final_data->{halted}) {
        print "\nThe following jobs requested all testing be halted:\n";
        for my $row (@$rows) {
            print "- filename: $row->[1]\n";
            print "  job_id: $row->[0]\n";
            print "  reason: $row->[2]\n" if $row->[2];
        }
    }

    if (my $rows = $final_data->{unseen}) {
        print "\nThe following jobs never ran:\n";
        for my $row (@$rows) {
            print "- filename: $row->[1]\n";
            print "  job_id: $row->[0]\n";
        }
    }
}

sub _subtest_paths {
    my ($map) = @_;

    my @paths;
    my @todo = @$map;
    my @state;
    while (my $st = shift @todo) {
        if (!ref($st)) {
            pop @state if $st eq 'pop';
            next;
        }
        push @state, $st->[0];
        push @paths, join(' -> ', @state);
        unshift @todo, (@{$st->[1]}, 'pop');
    }

    return @paths;
}

sub stringify_subtest_map {
    my ($map) = @_;

    my $out  = "";
    my @todo = @$map;
    my @state;
    while (my $st = shift @todo) {
        if (!ref($st)) {
            pop @state if $st eq 'pop';
            next;
        }
        push @state => $st->[0];
        $out .= join(' -> ' => @state) . "\n";
        unshift @todo => (@{$st->[1]}, 'pop');
    }

    return $out;
}

sub logger {
    my $self = shift;

    return $self->{+LOGGER} if $self->{+LOGGER};

    my $settings = $self->{+SETTINGS};

    return unless $settings->logging->log;

    my $file = $settings->logging->log_file;

    if ($settings->logging->bzip2) {
        no warnings 'once';
        require IO::Compress::Bzip2;
        $self->{+LOGGER} = IO::Compress::Bzip2->new($file) or die "Could not open log file '$file': $IO::Compress::Bzip2::Bzip2Error";
    }
    elsif ($settings->logging->gzip) {
        no warnings 'once';
        require IO::Compress::Gzip;
        $self->{+LOGGER} = IO::Compress::Gzip->new($file) or die "Could not open log file '$file': $IO::Compress::Gzip::GzipError";
    }
    else {
        $self->{+LOGGER} = open_file($file, '>');
    }

    for my $ext ('jsonl', 'jsonl.bz2', 'jsonl.gz') {
        my $name = "./lastlog.$ext";
        next unless -f $name;
        local ($!, $@) = (0, '');
        eval { unlink($name) } or warn "Could not unlink '$name': ($!) $@";
    }

    if ($file =~ m/\.(jsonl(?:\.(?:bz2|gz))?)$/) {
        my $ext  = $1;
        my $name = "./lastlog.$ext";
        if (eval { symlink($file, $name); 1 }) {
            $self->{+LAST_LOG} = $name;
        }
        else {
            warn "Could not symlink the log file to '$name': $@";
        }
    }

    return $self->{+LOGGER};
}

sub renderers {
    my $self = shift;

    return $self->{+RENDERERS} if $self->{+RENDERERS};

    my $settings = $self->{+SETTINGS};

    my @renderers;
    for my $class (@{$settings->display->renderers->{'@'}}) {
        require(mod2file($class));
        my $args     = $settings->display->renderers->{$class};
        my $renderer = $class->new(@$args, settings => $settings, command_class => ref($self));
        push @renderers => $renderer;
    }

    return $self->{+RENDERERS} = \@renderers;
}

sub collector_options { () }

sub start_collector {
    my $self = shift;

    my $dir        = $self->workdir;
    my $run        = $self->build_run();
    my $settings   = $self->settings;
    my $runner_pid = $self->runner_pid;

    my ($rh, $wh);
    pipe($rh, $wh) or die "Could not create pipe";

    my %options = (show_runner_output => 1);
    if ($settings->check_group('display')) {
        $options{show_runner_output}     = $settings->display->hide_runner_output ? 0 : 1;
        $options{truncate_runner_output} = $settings->display->truncate_runner_output;
    }

    %options = (
        %options,
        $self->collector_options(),
    );

    my $ipc = $self->ipc;
    $ipc->spawn(
        stdout      => $self->collector_writer,
        stdin       => $rh,
        no_set_pgrp => 1,
        command     => [
            $^X, $self->spawn_args($settings), $settings->harness->script,
            (map { "-D$_" } @{$settings->harness->dev_libs}),
            '--no-scan-plugins',    # Do not preload any plugin modules
            collector => 'Test2::Harness2::Collector',
            $dir, $run->run_id, $runner_pid,
            %options,
        ],
    );

    close($rh);
    print $wh encode_json($run) . "\n";
    close($wh);

    close($self->collector_writer());
}

sub start_runner {
    my $self = shift;
    my %args = @_;

    $args{monitor_preloads} //= $self->monitor_preloads;

    my $settings = $self->settings;
    my $dir      = $settings->workspace->workdir;

    my @prof;
    if ($settings->runner->nytprof) {
        push @prof => '-d:NYTProf';
    }

    # The runner command that used to be spawned directly (its stdout/stderr
    # tailed from output.log/error.log). It is now the exec target of a non-test
    # collector: chunk 4 step 1 wraps the `yath test` runner in a Test2::Collector
    # (is_test => 0) so its stdout/stderr become first-class, timestamped harness
    # events in runner-events.jsonl.zst -- the same wire format and reader path as
    # job events -- instead of flat tailed logs.
    my @runner_cmd = (
        $^X, @prof, $self->spawn_args($settings), $settings->harness->script,
        (map { "-D$_" } @{$settings->harness->dev_libs}),
        '--no-scan-plugins',    # Do not preload any plugin modules
        runner => $dir,
        %args,
    );

    my $runner_events_file = runner_events_file($dir);

    my $ipc  = $self->ipc;
    my $proc = $ipc->spawn(
        env_vars    => {@prof ? (NYTPROF => 'start=no:addpid=1') : ()},
        no_set_pgrp => 1,

        # The spawned child becomes the collector PARENT and never returns: it
        # runs the whole collector and POSIX::_exit()s. This mirrors
        # Test2::Harness2::Runner::Job::spawn_params and only works under the
        # fork-exec run_cmd (which invokes the coderef in the already-forked
        # child); the harness only supports fork-capable systems. The collector
        # forks the actual runner (exec, below), captures its stdout/stderr/exit,
        # and records the full stream into runner-events.jsonl.zst, so there are
        # no separate stdout/stderr files anymore. The parent MUST _exit() with
        # the runner child's verdict (collector_exit_code) so IPC's runner-death
        # detection / wait-status handling is unchanged.
        command => sub {
            require Test2::Collector;
            require Test2::Collector::Recorder::Zstd;
            my $info = Test2::Collector::collect(
                is_test  => 0,
                name     => 'runner',
                exec     => [@runner_cmd],
                recorder => Test2::Collector::Recorder::Zstd->new(file => $runner_events_file),
            );
            POSIX::_exit(collector_exit_code($info));
        },
    );

    $self->{+RUNNER_PID} = $proc->pid;

    return $proc;
}

sub parse_args {
    my $self     = shift;
    my $settings = $self->settings;
    my $args     = $self->args;

    my $dest = $settings->finder->search;
    for my $arg (@$args) {
        next if $arg eq '--';
        if ($arg eq '::') {
            $dest = $settings->run->test_args;
            next;
        }

        push @$dest => $arg;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::test - Run tests

=head1 DESCRIPTION

This yath command (which is also the default command) will run all the test
files for the current project. If no test files are specified this command will
look for the 't', and 't2' directories, as well as the 'test.pl' file.

This command is always recursive when given directories.

This command will add 'lib', 'blib/arch' and 'blib/lib' to the perl path for
you by default (after any -I's). You can specify -l if you just want lib, -b if
you just want the blib paths. If you specify both -l and -b both will be added
in the order you specify (order relative to any -I options will also be
preserved.  If you do not specify they will be added in this order: -I's, lib,
blib/lib, blib/arch. You can also add --no-lib and --no-blib to avoid both.

Any command line argument that is not an option will be treated as a test file
or directory of test files to be run.

If you wish to specify the ARGV for tests you may append them after '::'. This
is mainly useful for Test::Class::Moose and similar tools. EVERY test run will
get the same ARGV.


=head1 USAGE

    $ yath [YATH OPTIONS] test [OPTIONS]

=head2 OPTIONS

=head3 Plugins

=over 4

=item --no-scan-plugins

=item --no-no-scan-plugins

Normally yath scans for and loads all App::Yath2::Plugin::* modules in order to bring in command-line options they may provide. This flag will disable that. This is useful if you have a naughty plugin that is loading other modules when it should not.


=item -pPLUGIN

=item --plugin PLUGIN

=item --plugins PLUGIN

=item --plugin PLUGIN=arg1,arg2,...

=item --plugins PLUGIN=arg1,arg2,...

=item --plugin +App::Yath2::Plugin::PLUGIN

=item --plugins +App::Yath2::Plugin::PLUGIN

=item --no-plugins

Load a yath plugin.

Note: Can be specified multiple times


=back

=head3 Environment

=over 4

=item --persist-dir ARG

=item --persist-dir=ARG

=item --no-persist-dir

Where to find persistence files.


=item --pfile ARG

=item --pfile=ARG

=item --persist-file ARG

=item --persist-file=ARG

=item --no-persist-file

Where to find the persistence file. The default is /{system-tempdir}/project-yath-persist.json. If no project is specified then it will fall back to the current directory. If the current directory is not writable it will default to /tmp/yath-persist.json which limits you to one persistent runner on your system.


=item --project ARG

=item --project=ARG

=item --project-name ARG

=item --project-name=ARG

=item --no-project

This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file. This is necessary for a persistent runner.


=back

=head3 Developer

=over 4

=item -D

=item -Dlib

=item -D=lib

=item --dev-lib

=item --dev-lib=lib

=item --no-dev-lib

Add paths to @INC before loading ANYTHING. This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.

Note: Can be specified multiple times


=back

=head3 Help and Debugging

=over 4

=item -d

=item --dummy

=item --no-dummy

Dummy run, do not actually execute anything

Can also be set with the following environment variables: C<T2_HARNESS_DUMMY>

The following environment variables will be cleared after arguments are processed: C<T2_HARNESS_DUMMY>


=item -h

=item -h=Group

=item --help

=item --help=Group

=item --no-help

exit after showing help information


=item -i

=item --interactive

=item --no-interactive

Use interactive mode, 1 test at a time, stdin forwarded to it


=item -k

=item --keep-dir

=item --keep-dirs

=item --no-keep-dirs

Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.


=item --procname-prefix ARG

=item --procname-prefix=ARG

=item --no-procname-prefix

Add a prefix to all proc names (as seen by ps).


=item --show-opts

=item --show-opts=group

=item --no-show-opts

Exit after showing what yath thinks your options mean


=item --summary

=item --summary=/path/to/summary.json

=item --no-summary

Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.


=item -V

=item --version

=item --no-version

Exit after showing a helpful usage message


=back

=head3 Collector Options

=over 4

=item --max-open-jobs 18

=item --no-max-open-jobs

Maximum number of jobs a collector can process at a time, if more jobs are pending their output will be delayed until the earlier jobs have been processed. (Default: double the -j value)


=item --max-poll-events 1000

=item --no-max-poll-events

Maximum number of events to poll from a job before jumping to the next job. (Default: 1000)


=back

=head3 Cover Options

=over 4

=item --cover-agg ByRun

=item --cover-agg ByTest

=item --cover-aggregator ByRun

=item --cover-aggregator ByTest

=item --cover-agg +Custom::Aggregator

=item --cover-aggregator +Custom::Aggregator

=item --no-cover-aggregator

Choose a custom aggregator subclass


=item --cover-class ARG

=item --cover-class=ARG

=item --no-cover-class

Choose a Test2::Plugin::Cover subclass


=item --cover-dir ARG

=item --cover-dir=ARG

=item --cover-dirs ARG

=item --cover-dirs=ARG

=item --cover-dir '["json","list"]'

=item --cover-dir='["json","list"]'

=item --cover-dirs '["json","list"]'

=item --cover-dirs='["json","list"]'

=item --no-cover-dirs

NO DESCRIPTION - FIX ME

Note: Can be specified multiple times


=item --cover-exclude-private

=item --no-cover-exclude-private




=item --cover-files

=item --no-cover-files

Use Test2::Plugin::Cover to collect coverage data for what files are touched by what tests. Unlike Devel::Cover this has very little performance impact (About 4% difference)


=item --cover-from path/to/log.jsonl

=item --cover-from path/to/coverage.jsonl

=item --cover-from http://example.com/coverage

=item --no-cover-from

This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will not be run if the file/url is invalid.


=item --cover-from-type log

=item --cover-from-type json

=item --cover-from-type jsonl

=item --no-cover-from-type

File type for coverage source. Usually it can be detected, but when it cannot be you should specify. "json" is old style single-blob coverage data, "jsonl" is the new by-test style, "log" is a logfile from a previous run.


=item --cover-manager My::Coverage::Manager

=item --no-cover-manager

Coverage 'from' manager to use when coverage data does not provide one


=item --cover-maybe-from path/to/log.jsonl

=item --cover-maybe-from path/to/coverage.jsonl

=item --cover-maybe-from http://example.com/coverage

=item --no-cover-maybe-from

This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will coninue if even if the coverage file/url is invalid.


=item --cover-maybe-from-type log

=item --cover-maybe-from-type json

=item --cover-maybe-from-type jsonl

=item --no-cover-maybe-from-type

Same as "from_type" but for "maybe_from". Defaults to "from_type" if that is specified, otherwise auto-detect


=item --cover-metrics

=item --no-cover-metrics




=item --cover-type ARG

=item --cover-type=ARG

=item --cover-types ARG

=item --cover-types=ARG

=item --cover-type '["json","list"]'

=item --cover-type='["json","list"]'

=item --cover-types '["json","list"]'

=item --cover-types='["json","list"]'

=item --no-cover-types

NO DESCRIPTION - FIX ME

Note: Can be specified multiple times


=item --cover-write

=item --cover-write=coverage.json

=item --cover-write=coverage.jsonl

=item --no-cover-write

Create a json or jsonl file of all coverage data seen during the run (This implies --cover-files).


=back

=head3 Display Options

=over 4

=item --color

=item --no-color

Turn color on, default is true if STDOUT is a TTY.

Can also be set with the following environment variables: C<YATH_COLOR>, C<CLICOLOR_FORCE>

The following environment variables will be set after arguments are processed: C<YATH_COLOR>


=item --hide-runner-output

=item --no-hide-runner-output

Hide output from the runner, showing only test output. (See Also truncate_runner_output)


=item --no-final-table

=item --no-no-final-table

When printing final results, don't use table-style display


=item --no-wrap

=item --no-no-wrap

Do not do fancy text-wrapping, let the terminal handle it


=item --progress

=item --no-progress

Toggle progress indicators. On by default if STDOUT is a TTY. You can use --no-progress to disable the 'events seen' counter and buffered event pre-display


=item -q

=item -qq

=item -qqq..

=item -q=COUNT

=item --quiet

=item --quiet=COUNT

=item --no-quiet

Be very quiet.

Note: Can be specified multiple times, counter bumps each time it is used.


=item --renderer +My::Renderer

=item --renderers +My::Renderer

=item --renderer Renderer=arg1,arg2,...

=item --renderers Renderer=arg1,arg2,...

=item --no-renderers

Specify renderers, (Default: "Formatter=Test2"). Use "+" to give a fully qualified module name. Without "+" "Test2::Harness2::Renderer::" will be prepended to your argument.

Note: Can be specified multiple times


=item -T

=item --show-times

=item --no-show-times

Show the timing data for each job


=item --term-size 80

=item --term-width 80

=item --term-size 200

=item --term-width 200

=item --no-term-width

Alternative to setting $TABLE_TERM_SIZE. Setting this will override the terminal width detection to the number of characters specified.

Can also be set with the following environment variables: C<TABLE_TERM_SIZE>

The following environment variables will be set after arguments are processed: C<TABLE_TERM_SIZE>


=item --truncate-runner-output

=item --no-truncate-runner-output

Only show runner output that was generated after the current command. This is only useful with a persistent runner.


=item -v

=item -vv

=item -vvv..

=item -v=COUNT

=item --verbose

=item --verbose=COUNT

=item --no-verbose

Be more verbose

Note: Can be specified multiple times, counter bumps each time it is used.


=back

=head3 Finder Options

=over 4

=item --changed path/to/file

=item --no-changed

Specify one or more files as having been changed.

Note: Can be specified multiple times


=item --changed-only

=item --no-changed-only

Only search for tests for changed files (Requires a coverage data source, also requires a list of changes either from the --changed option, or a plugin that implements changed_files() or changed_diff())


=item --changes-diff path/to/diff.diff

=item --no-changes-diff

Path to a diff file that should be used to find changed files for use with --changed-only. This must be in the same format as `git diff -W --minimal -U1000000`


=item --changes-exclude-file path/to/file

=item --changes-exclude-files path/to/file

=item --no-changes-exclude-files

Specify one or more files to ignore when looking at changes

Note: Can be specified multiple times


=item --changes-exclude-loads

=item --no-changes-exclude-loads

Exclude coverage tests which only load changed files, but never call code from them. (default: off)


=item --changes-exclude-nonsub

=item --no-changes-exclude-nonsub

Exclude changes outside of subroutines (perl files only) (default: off)


=item --changes-exclude-opens

=item --no-changes-exclude-opens

Exclude coverage tests which only open() changed files, but never call code from them. (default: off)


=item --changes-exclude-pattern '(apple|pear|orange)'

=item --changes-exclude-patterns '(apple|pear|orange)'

=item --no-changes-exclude-patterns

Ignore files matching this pattern when looking for changes. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.

Note: Can be specified multiple times


=item --changes-filter-file path/to/file

=item --changes-filter-files path/to/file

=item --no-changes-filter-files

Specify one or more files to check for changes. Changes to other files will be ignored

Note: Can be specified multiple times


=item --changes-filter-pattern '(apple|pear|orange)'

=item --changes-filter-patterns '(apple|pear|orange)'

=item --no-changes-filter-patterns

Specify a pattern for change checking. When only running tests for changed files this will limit which files are checked for changes. Only files that match this pattern will be checked. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.

Note: Can be specified multiple times


=item --changes-include-whitespace

=item --no-changes-include-whitespace

Include changed lines that are whitespace only (default: off)


=item --changes-plugin Git

=item --changes-plugin +App::Yath2::Plugin::Git

=item --no-changes-plugin

What plugin should be used to detect changed files.


=item --default-at-search ARG

=item --default-at-search=ARG

=item --default-at-search '["json","list"]'

=item --default-at-search='["json","list"]'

=item --no-default-at-search

Specify the default file/dir search when 'AUTHOR_TESTING' is set. Defaults to './xt'. The default AT search is only used if no files were specified at the command line

Note: Can be specified multiple times


=item --default-search ARG

=item --default-search=ARG

=item --default-search '["json","list"]'

=item --default-search='["json","list"]'

=item --no-default-search

Specify the default file/dir search. defaults to './t', './t2', and 'test.pl'. The default search is only used if no files were specified at the command line

Note: Can be specified multiple times


=item --durations file.json

=item --durations http://example.com/durations.json

=item --no-durations

Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.


=item --Dt ARG

=item --Dt=ARG

=item --durations-threshold ARG

=item --durations-threshold=ARG

=item --no-durations-threshold

Only fetch duration data if running at least this number of tests. Default (-j value + 1)


=item --exclude-file t/nope.t

=item --exclude-files t/nope.t

=item --no-exclude-files

Exclude a file from testing

Note: Can be specified multiple times


=item --exclude-list file.txt

=item --exclude-lists file.txt

=item --exclude-list http://example.com/exclusions.txt

=item --exclude-lists http://example.com/exclusions.txt

=item --no-exclude-lists

Point at a file or url which has a new line separated list of test file names to exclude from testing. Starting a line with a '#' will comment it out (for compatibility with Test2::Aggregate list files).

Note: Can be specified multiple times


=item --exclude-pattern t/nope.t

=item --exclude-patterns t/nope.t

=item --no-exclude-patterns

Exclude a pattern from testing, matched using m/$PATTERN/

Note: Can be specified multiple times


=item --ext ARG

=item --ext=ARG

=item --extension ARG

=item --extension=ARG

=item --extensions ARG

=item --extensions=ARG

=item --ext '["json","list"]'

=item --ext='["json","list"]'

=item --extension '["json","list"]'

=item --extension='["json","list"]'

=item --extensions '["json","list"]'

=item --extensions='["json","list"]'

=item --no-extensions

Specify valid test filename extensions, default: t and t2

Note: Can be specified multiple times


=item --finder MyFinder

=item --finder +Test2::Harness2::Finder::MyFinder

=item --no-finder

Specify what Finder subclass to use when searching for files/processing the file list. Use the "+" prefix to specify a fully qualified namespace, otherwise Test2::Harness2::Finder::XXX namespace is assumed.


=item --maybe-durations file.json

=item --maybe-durations http://example.com/durations.json

=item --no-maybe-durations

Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.


=item --no-long

=item --no-no-long

Do not run tests that have their duration flag set to 'LONG'


=item --only-long

=item --no-only-long

Only run tests that have their duration flag set to 'LONG'


=item --rerun

=item --rerun=path/to/log.jsonl

=item --rerun=plugin_specific_string

=item --no-rerun

Re-Run tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.


=item --rerun-modes all,failed,missed,passed,retried

=item --no-rerun-modes

=item /^--(no-)?(?^u:rerun-(all|failed|missed|passed|retried)(=.+)?$/

Pick which test categories to re-run. all:     Re-Run all tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that. failed:  Re-Run failed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that. missed:  Run missed tests from a previously aborted/stopped run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that. passed:  Re-Run passed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that. retried: Re-Run retried tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.

Note: This will turn on the 'rerun' option. If the --rerun-MODE form is used, you can specify the log file with --rerun-MODE=logfile.

Note: Can be specified multiple times


=item --rerun-plugin Foo

=item --rerun-plugins Foo

=item --rerun-plugin +App::Yath2::Plugin::Foo

=item --rerun-plugins +App::Yath2::Plugin::Foo

=item --no-rerun-plugins

What plugin(s) should be used for rerun (will fallback to other plugins if the listed ones decline the value, this is just used to set an order of priority)

Note: Can be specified multiple times


=item --search ARG

=item --search=ARG

=item --search '["json","list"]'

=item --search='["json","list"]'

=item --no-search

List of tests and test directories to use instead of the default search paths. Typically these can simply be listed as command line arguments without the --search prefix.

Note: Can be specified multiple times


=item --show-changed-files

=item --no-show-changed-files

Print a list of changed files if any are found


=back

=head3 Formatter Options

=over 4

=item --formatter ARG

=item --formatter=ARG

=item --no-formatter

Specify the formatter to use. (Default: "Test2", or "QVF" if --qvf is set)


=item --qvf

=item --no-qvf

[Q]uiet, but [V]erbose on [F]ailure. Hide all output from tests when they pass, except to say they passed. If a test fails then ALL output from the test is verbosely output.


=item --show-job-end

=item --no-show-job-end

Show output when a job ends. (Default: on)


=item --show-job-info

=item --no-show-job-info

Show the job configuration when a job starts. (Default: off, unless -vv)


=item --show-job-launch

=item --no-show-job-launch

Show output for the start of a job. (Default: off unless -v)


=item --show-run-info

=item --no-show-run-info

Show the run configuration when a run starts. (Default: off, unless -vv)


=back

=head3 Git Options

=over 4

=item --git-change-base HEAD^

=item --git-change-base master

=item --git-change-base df22abe4

=item --no-git-change-base

Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.


=back

=head3 Logging Options

=over 4

=item -B

=item --bz2

=item --bzip2

=item --bzip2-log

=item --no-bzip2

Use bzip2 compression when writing the log. This option implies -L. The .bz2 prefix is added to log file name for you


=item -G

=item --gz

=item --gzip

=item --gzip-log

=item --no-gzip

Use gzip compression when writing the log. This option implies -L. The .gz prefix is added to log file name for you


=item -L

=item --log

=item --no-log

Turn on logging


=item --log-dir ARG

=item --log-dir=ARG

=item --no-log-dir

Specify a log directory. Will fall back to the system temp dir.


=item -FARG

=item -F ARG

=item -F=ARG

=item --log-file ARG

=item --log-file=ARG

=item --no-log-file

Specify the name of the log file. This option implies -L.


=item --lff ARG

=item --lff=ARG

=item --log-file-format ARG

=item --log-file-format=ARG

=item --no-log-file-format

Specify the format for automatically-generated log files. Overridden by --log-file, if given. This option implies -L (Default: $YATH_LOG_FILE_FORMAT, if that is set, or else "%!P%Y-%m-%d_%H:%M:%S_%!U.jsonl"). This is a string in which percent-escape sequences will be replaced as per POSIX::strftime. The following special escape sequences are also replaced: (%!P : Project name followed by a ~, if a project is defined, otherwise empty string) (%!U : the unique test run ID) (%!p : the process ID) (%!S : the number of seconds since local midnight UTC)

Can also be set with the following environment variables: C<YATH_LOG_FILE_FORMAT>, C<TEST2_HARNESS_LOG_FORMAT>


=back

=head3 Notification Options

=over 4

=item --notify-email foo@example.com

=item --no-notify-email

Email the test results to the specified email address(es)

Note: Can be specified multiple times


=item --notify-email-fail foo@example.com

=item --no-notify-email-fail

Email failing results to the specified email address(es)

Note: Can be specified multiple times


=item --notify-email-from foo@example.com

=item --no-notify-email-from

If any email is sent, this is who it will be from


=item --notify-email-owner

=item --no-notify-email-owner

Email the owner of broken tests files upon failure. Add `# HARNESS-META-OWNER foo@example.com` to the top of a test file to give it an owner


=item --notify-no-batch-email

=item --no-notify-no-batch-email

Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.


=item --notify-no-batch-slack

=item --no-notify-no-batch-slack

Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.


=item --notify-slack '#foo'

=item --notify-slack '@bar'

=item --no-notify-slack

Send results to a slack channel and/or user

Note: Can be specified multiple times


=item --notify-slack-fail '#foo'

=item --notify-slack-fail '@bar'

=item --no-notify-slack-fail

Send failing results to a slack channel and/or user

Note: Can be specified multiple times


=item --notify-slack-owner

=item --no-notify-slack-owner

Send slack notifications to the slack channels/users listed in test meta-data when tests fail.


=item --notify-slack-url https://hooks.slack.com/...

=item --no-notify-slack-url

Specify an API endpoint for slack webhook integrations


=item --notify-msg ARG

=item --notify-msg=ARG

=item --notify-text ARG

=item --notify-text=ARG

=item --notify-message ARG

=item --notify-message=ARG

=item --no-notify-text

Add a custom text snippet to email/slack notifications


=item --notify-text-module ARG

=item --notify-text-module=ARG

=item --notify-message-module ARG

=item --notify-message-module=ARG

=item --no-notify-text-module

Use the specified module to generate messages for emails and/or slack.


=back

=head3 Run Options

=over 4

=item -A

=item --author-testing

=item --no-author-testing

This will set the AUTHOR_TESTING environment to true

Can also be set with the following environment variables: C<AUTHOR_TESTING>

The following environment variables will be set after arguments are processed: C<AUTHOR_TESTING>


=item --dbi-profiling

=item --no-dbi-profiling

Use Test2::Plugin::DBIProfile to collect database profiling data


=item -EVAR=VAL

=item -E VAR=VAL

=item --env-var VAR=VAL

=item --no-env-var

Set environment variables to set when each test is run.

Note: Can be specified multiple times


=item --uuids

=item --event-uuids

=item --no-event-uuids

Use Test2::Plugin::UUID inside tests (default: on)


=item -f JSON_STRING

=item -f name:details

=item --fields JSON_STRING

=item --fields name:details

=item --no-fields

Add custom data to the harness run

Note: Can be specified multiple times


=item --input ARG

=item --input=ARG

=item --no-input

Input string to be used as standard input for ALL tests. See also: --input-file


=item --input-file ARG

=item --input-file=ARG

=item --no-input-file

Use the specified file as standard input to ALL tests


=item --io-events

=item --no-io-events

Use Test2::Plugin::IOEvents inside tests to turn all prints into test2 events (default: off)


=item --link 'https://jenkins.work/job/42'

=item --link 'https://travis.work/builds/42'

=item --link 'https://buildbot.work/builders/foo/builds/42'

=item --no-link

Provide one or more links people can follow to see more about this run.

Note: Can be specified multiple times


=item -m ARG

=item -m=ARG

=item -m '["json","list"]'

=item -m='["json","list"]'

=item --load ARG

=item --load=ARG

=item --load-module ARG

=item --load-module=ARG

=item --load '["json","list"]'

=item --load='["json","list"]'

=item --load-module '["json","list"]'

=item --load-module='["json","list"]'

=item --no-load

Load a module in each test (after fork). The "import" method is not called.

Note: Can be specified multiple times


=item -M Module

=item -M Module=import_arg1,arg2,...

=item --loadim Module

=item --load-import Module

=item --loadim Module=import_arg1,arg2,...

=item --load-import Module=import_arg1,arg2,...

=item --no-load-import

Load a module in each test (after fork). Import is called.

Note: Can be specified multiple times


=item --mem-usage

=item --no-mem-usage

Use Test2::Plugin::MemUsage inside tests (default: on)


=item -rARG

=item -r ARG

=item -r=ARG

=item --retry ARG

=item --retry=ARG

=item --no-retry

Run any jobs that failed a second time. NOTE: --retry=1 means failing tests will be attempted twice!


=item --retry-iso

=item --retry-isolated

=item --no-retry-isolated

If true then any job retries will be done in isolation (as though -j1 was set)


=item --id ARG

=item --id=ARG

=item --run-id ARG

=item --run-id=ARG

=item --no-run-id

Set a specific run-id. (Default: a UUID)


=item --stream

=item --use-stream

=item --no-stream

=item --TAP

The TAP format is lossy and clunky. Test2::Harness2 normally uses a newer streaming format to receive test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help.


=item --test-args ARG

=item --test-args=ARG

=item --test-args '["json","list"]'

=item --test-args='["json","list"]'

=item --no-test-args

Arguments to pass in as @ARGV for all tests that are run. These can be provided easier using the '::'  argument separator.

Note: Can be specified multiple times


=back

=head3 Runner Options

=over 4

=item --abort-on-bail

=item --no-abort-on-bail

Abort all testing if a bail-out is encountered (default: on)


=item -b

=item --blib

=item --no-blib

(Default: include if it exists) Include 'blib/lib' and 'blib/arch' in your module path


=item --cover

=item --cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl

=item --no-cover

Use Devel::Cover to calculate test coverage. This disables forking. If no args are specified the following are used: -silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl

Can also be set with the following environment variables: C<T2_DEVEL_COVER>

The following environment variables will be set after arguments are processed: C<T2_DEVEL_COVER>


=item --dump-depmap

=item --no-dump-depmap

When using staged preload, dump the depmap for each stage as json files


=item --et SECONDS

=item --event-timeout SECONDS

=item --no-event-timeout

Kill test if no output is received within timeout period. (Default: 60 seconds). Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis. This prevents a hung test from running forever.


=item --fail-on-resource-skip

=item --no-fail-on-resource-skip

Treat resource-skipped tests as failures instead of skips. When enabled, tests that would be skipped due to unavailable resources will be marked as failing.


=item -I ARG

=item -I=ARG

=item -I '["json","list"]'

=item -I='["json","list"]'

=item --include ARG

=item --include=ARG

=item --include '["json","list"]'

=item --include='["json","list"]'

=item --no-include

Add a directory to your include paths

Note: Can be specified multiple times


=item -j4

=item -j8:2

=item --jobs 4

=item --jobs 8:2

=item --job-count 4

=item --job-count 8:2

=item --no-job-count

Set the number of concurrent jobs to run. Add a :# if you also wish to designate multiple slots per test. 8:2 means 8 slots, but each test gets 2 slots, so 4 tests run concurrently. Tests can find their concurrency assignemnt in the "T2_HARNESS_MY_JOB_CONCURRENCY" environment variable.

Can also be set with the following environment variables: C<YATH_JOB_COUNT>, C<T2_HARNESS_JOB_COUNT>, C<HARNESS_JOB_COUNT>

The following environment variables will be cleared after arguments are processed: C<YATH_JOB_COUNT>, C<T2_HARNESS_JOB_COUNT>, C<HARNESS_JOB_COUNT>


=item -l

=item --lib

=item --no-lib

(Default: include if it exists) Include 'lib' in your module path


=item --nytprof

=item --no-nytprof

Use Devel::NYTProf on tests. This will set addpid=1 for you. This works with or without fork.


=item --pet SECONDS

=item --post-exit-timeout SECONDS

=item --no-post-exit-timeout

Stop waiting post-exit after the timeout period. (Default: 15 seconds) Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness2 detects an incomplete plan after the test exits it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.


=item -WARG

=item -W ARG

=item -W=ARG

=item --Pt ARG

=item --Pt=ARG

=item --preload-threshold ARG

=item --preload-threshold=ARG

=item --no-preload-threshold

Only do preload if at least N tests are going to be run. In some cases a full preload takes longer than simply running the tests, this lets you specify a minimum number of test jobs that will be run for preload to happen. This has no effect for a persistent runner. The default is 0, and it means always preload.


=item -P ARG

=item -P=ARG

=item -P '["json","list"]'

=item -P='["json","list"]'

=item --preload ARG

=item --preload=ARG

=item --preloads ARG

=item --preloads=ARG

=item --preload '["json","list"]'

=item --preload='["json","list"]'

=item --preloads '["json","list"]'

=item --preloads='["json","list"]'

=item --no-preloads

Preload a module before running tests

Note: Can be specified multiple times


=item -R Port

=item --resource Port

=item --resource +Test2::Harness2::Runner::Resource::Port

=item --no-resource

Use a resource module to assign resource assignments to individual tests

Note: Can be specified multiple times


=item --rt SECONDS

=item --resource-timeout SECONDS

=item --no-resource-timeout

Abort the test run if no tests have been able to start for SECONDS seconds while there are pending tests and none running. This is useful when a resource class is broken and always claims a resource will become available, preventing yath from ever finishing. (Default: 0, meaning no timeout)


=item --runner-id ARG

=item --runner-id=ARG

=item --no-runner-id

Runner ID (usually a generated uuid)


=item --shared-jobs-config .sharedjobslots.yml

=item --shared-jobs-config relative/path/.sharedjobslots.yml

=item --shared-jobs-config /absolute/path/.sharedjobslots.yml

=item --no-shared-jobs-config

Where to look for a shared slot config file. If a filename with no path is provided yath will search the current and all parent directories for the name.


=item -x2

=item --slots-per-job 2

=item --no-slots-per-job

This sets the number of slots each job will use (default 1). This is normally set by the ':#' in '-j#:#'.

Can also be set with the following environment variables: C<T2_HARNESS_JOB_CONCURRENCY>

The following environment variables will be cleared after arguments are processed: C<T2_HARNESS_JOB_CONCURRENCY>


=item -S ARG

=item -S=ARG

=item -S '["json","list"]'

=item -S='["json","list"]'

=item --switch ARG

=item --switch=ARG

=item --switch '["json","list"]'

=item --switch='["json","list"]'

=item --no-switch

Pass the specified switch to perl for each test. This is not compatible with preload.

Note: Can be specified multiple times


=item --tlib

=item --no-tlib

(Default: off) Include 't/lib' in your module path


=item --unsafe-inc

=item --no-unsafe-inc

perl is removing '.' from @INC as a security concern. This option keeps things from breaking for now.

Can also be set with the following environment variables: C<PERL_USE_UNSAFE_INC>


=item --fork

=item --use-fork

=item --no-use-fork

(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' comment in their header to disable forking only for those tests.

Can also be set with the following environment variables: C<!T2_NO_FORK>, C<T2_HARNESS_FORK>, C<!T2_HARNESS_NO_FORK>, C<YATH_FORK>, C<!YATH_NO_FORK>


=item --timeout

=item --use-timeout

=item --no-use-timeout

(default: on) Enable/disable timeouts


=back

=head3 Workspace Options

=over 4

=item -C

=item --clear

=item --no-clear

Clear the work directory if it is not already empty


=item -tARG

=item -t ARG

=item -t=ARG

=item --tmpdir ARG

=item --tmpdir=ARG

=item --tmp-dir ARG

=item --tmp-dir=ARG

=item --tmp-dir ARG

=item --tmp-dir=ARG

=item --no-tmp-dir

Use a specific temp directory (Default: use system temp dir)

Can also be set with the following environment variables: C<T2_HARNESS_TEMP_DIR>, C<YATH_TEMP_DIR>, C<TMPDIR>, C<TEMPDIR>, C<TMP_DIR>, C<TEMP_DIR>


=item -wARG

=item -w ARG

=item -w=ARG

=item --workdir ARG

=item --workdir=ARG

=item --no-workdir

Set the work directory (Default: new temp directory)

Can also be set with the following environment variables: C<T2_WORKDIR>, C<YATH_WORKDIR>

The following environment variables will be cleared after arguments are processed: C<T2_WORKDIR>, C<YATH_WORKDIR>


=back

=head3 YathUI Options

=over 4

=item --yathui-api-key ARG

=item --yathui-api-key=ARG

=item --no-yathui-api-key

Yath-UI API key. This is not necessary if your Yath-UI instance is set to single-user


=item --yathui-coverage

=item --no-yathui-coverage

Poll coverage data from Yath-UI to determine what tests should be run for changed files


=item --yathui-durations

=item --no-yathui-durations

Poll duration data from Yath-UI to help order tests efficiently


=item --yathui-grace

=item --no-yathui-grace

If yath cannot connect to yath-ui it normally throws an error, use this to make it fail gracefully. You get a warning, but things keep going.


=item --yathui-long-duration 10

=item --no-yathui-long-duration

Minimum duration length (seconds) before a test goes from MEDIUM to LONG


=item --yathui-medium-duration 5

=item --no-yathui-medium-duration

Minimum duration length (seconds) before a test goes from SHORT to MEDIUM


=item --yathui-mode qvf

=item --yathui-mode qvfd

=item --yathui-mode summary

=item --yathui-mode complete

=item --no-yathui-mode

Set the upload mode (default 'qvfd')


=item --yathui-project ARG

=item --yathui-project=ARG

=item --no-yathui-project

The Yath-UI project for your test results


=item --yathui-retry

=item --yathui-retry=COUNT

=item --no-yathui-retry

How many times to try an operation before giving up

Note: Can be specified multiple times, counter bumps each time it is used.


=item --yathui-upload

=item --no-yathui-upload

Upload the log to Yath-UI


=item --yathui-url http://my-yath-ui.com/...

=item --yathui-uri http://my-yath-ui.com/...

=item --no-yathui-url

Yath-UI url


=back


=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut


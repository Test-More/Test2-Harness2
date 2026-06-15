package Test2::Harness2::Runner::Job;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/confess croak/;
use Config qw/%Config/;
use List::Util qw/min/;
use POSIX();
use Scalar::Util qw/weaken blessed/;
use Test2::Util qw/CAN_REALLY_FORK/;
use Time::HiRes qw/time/;

use File::Spec();
use File::Temp();

use Test2::Harness2::Util qw/fqmod clean_path write_file mod2file open_file process_includes chmod_tmp collector_exit_code/;
use Test2::Harness2::IPC;

use parent 'Test2::Harness2::IPC::Process';
use Test2::Harness2::Util::HashBase(
    qw{ <task <runner <run <settings }, # required
    qw{
        <fork_callback

        +verbose

        +via

        +run_dir +job_dir +tmp_dir

        +ch_dir +unsafe_inc

        +use_fork +use_w_switch

        +includes +runner_includes
        +switches
        +cli_includes
        +cli_options

        +smoke
        +retry +retry_isolated +is_try

        +args +file +run_file

        +out_file +err_file +in_file +bail_file +events_file

        +load +load_import

        +event_uuids +mem_usage +io_events

        +env_vars

        +event_timeout +post_exit_timeout +use_timeout

        +switches_from_env

        +min_slots
        +max_slots
    }
);

sub category { 'job' }

sub init {
    my $self = shift;

    croak "'runner' is a required attribute"   unless $self->{+RUNNER};
    croak "'run' is a required attribute"      unless $self->{+RUN};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    delete $self->{+JOB_DIR};

    # Avoid a ref cycle
    #weaken($self->{+RUNNER});

    my $task = $self->{+TASK} or croak "'task' is a required attribute";

    confess "Task does not have a job ID" unless $task->{job_id};
    confess "Task does not have a file"   unless $task->{file};
}

sub job_id { $_[0]->{+TASK}->{job_id} }

sub prepare_dir {
    my $self = shift;

    $self->job_dir();
    $self->tmp_dir();
}

sub via {
    my $self = shift;

    return undef if $self->{+SETTINGS}->debug->dummy;
    return undef if $self->{+TASK}->{resource_skip};

    return $self->{+VIA} if exists $self->{+VIA};

    my $task = $self->{+TASK};
    return $self->{+VIA} = $task->{via} if $task->{via};

    return $self->{+VIA} = $self->{+FORK_CALLBACK} if $self->{+FORK_CALLBACK} && $self->use_fork;

    return $self->{+VIA} = undef;
}

sub spawn_params {
    my $self = shift;

    # The forked job child becomes the Test2-Collector collector parent. The
    # collector forks the actual test child internally (exec, here), captures
    # its stdout/stderr/exit, and records the full event stream (events +
    # transitions + final_state + process_exit) into events.jsonl.zst. There
    # are therefore no separate stdout/stderr/exit files: the collector owns
    # all of that.
    # NOTE: this command coderef never returns -- it runs the whole collector
    # and POSIX::_exit()s. That only works under the fork-exec run_cmd
    # (_run_cmd_fork), which invokes the coderef in the already-forked child.
    # The harness only supports fork-capable systems (Makefile.PL dies "OS
    # unsupported" without d_fork), so the non-fork _run_cmd_spwn path (which
    # would run this in the parent) is never reached. chdir and env are applied
    # inside run_under_collector (collect's chdir/child_env); run_cmd's own
    # chdir/env handling never runs given the never-returning coderef, so they
    # are intentionally NOT returned here.
    return {
        command => sub {
            my $info = $self->run_under_collector($self->collector_target);
            POSIX::_exit($self->_collector_exit_code($info));
        },
    };
}

# Decide the collector-parent's exit code from the collect() info hash. The
# RUNNER reaps this process and uses its wait status to drive retry/fail logic
# (see Test2::Harness2::Runner::set_proc_exit), so the collector-parent MUST
# exit with the TEST child's verdict, NOT merely its own (collector) health:
#   - collector itself failed  -> 255 (a harness/collector error, not a test
#     result; the runner treats non-zero as failure, which is correct here too).
#   - otherwise                -> the test child's exit status: WEXITSTATUS when
#     non-zero, or 1 if the test died by signal. Zero only on a clean pass, so a
#     passing test still makes the runner see success.
# POSIX::_exit(N) makes the runner observe wait-status N<<8, parse_exit -> err=N.
sub _collector_exit_code {
    my $self = shift;
    my ($info) = @_;

    # Collector-failure (255) and the err/sig numeric mapping are shared with the
    # non-test runner collector wrapper (App::Yath2::Command::test); keep them in
    # the one Util helper so exit-status fidelity never diverges. On a 255
    # collector failure return immediately -- the job-specific bail/final_state
    # layering below only makes sense when the collector itself was healthy.
    # collector_exit_code already returns 255 whenever the collector is
    # unhealthy, so short-circuit on that same condition: the job-specific
    # bail/final_state layering below only makes sense when the collector itself
    # was healthy.
    my $code = collector_exit_code($info);
    return $code unless $info && $info->{collector} && $info->{collector}{ok};

    # A bail-out (or any other halt) lives only in the audited final_state, not
    # in the OS exit status. Persist the reason so the runner's bailed_out() can
    # see it (--abort-on-bail) now that there is no stdout file to scan.
    my $fs = $info->{final_state};
    if ($fs && defined($fs->{halt}) && length($fs->{halt})) {
        write_file($self->bail_file, $fs->{halt});
    }

    return $code if $code;

    # Test2-Collector can audit a test as FAILED while the process exits zero
    # (raw TAP "not ok", a missing/invalid plan, --fail-on-resource-skip TAP, a
    # bail-out). The runner drives retry/fail off this wait status, so a clean OS
    # exit must still report failure when the audited verdict failed -- otherwise
    # an audit-only failure is silently treated as a pass and never retried.
    return 1 if $fs && !$fs->{pass};

    return 0;
}

# Build the exec target (and any skip/fail short-circuit) for the spawn path.
# The spawn path always exec()s a perl (or binary) command inside the
# collector's child; the preload/fork path runs the test in-process and wraps
# its own run_sub (see App::Yath2::Command::runner), so it does not come here.
sub collector_target {
    my $self = shift;

    my $task = $self->{+TASK};

    my $skip;
    my $resource_skip_is_fail;
    $skip = 'dummy mode' if $self->{+SETTINGS}->debug->dummy;
    if ($task->{resource_skip}) {
        my $msg = "Some resources are not available: " . join(', ' => @{$task->{resource_skip}});
        $skip = $msg;
        $resource_skip_is_fail = 1 if $self->{+SETTINGS}->runner->fail_on_resource_skip;
    }

    if (!$skip && ($task->{binary} || $task->{non_perl})) {
        my $file = clean_path($self->ch_dir ? $self->file : $self->rel_file);
        my @cmd  = ($file, $self->args);
        unshift @cmd => $^X if $task->{non_perl} && !(-x $file) && !$task->{binary};
        return (exec => \@cmd);
    }

    my @skip_or_fail;
    if ($skip && $resource_skip_is_fail) {
        @skip_or_fail = ('-e', "print \"1..1\\nnot ok 1 - $skip\\n\"");
    }
    elsif ($skip) {
        @skip_or_fail = ('-e', "print \"1..0 # SKIP $skip\"");
    }

    return (
        exec => [
            $^X,
            $self->cli_includes,
            $self->{+SETTINGS}->runner->nytprof ? ('-d:NYTProf') : (),
            $self->switches,
            $self->cli_options,

            @skip_or_fail ? @skip_or_fail : ($self->run_file),

            $self->args,
        ],
    );
}

# Runs in the forked job child (spawn path) or as the collector wrapper for the
# preload/fork path. Becomes the Test2-Collector collector parent: collect()
# forks the actual test child (exec for the spawn path, or a run_sub the
# preload path supplies) and records the full stream into events.jsonl.zst.
sub run_under_collector {
    my $self = shift;
    my (@target) = @_;

    require Test2::Collector;
    require Test2::Collector::Recorder::Zstd;

    my $in_file = $self->in_file;

    # Timeout mapping to Test2::Collector:
    #   event_timeout     -> silence_timeout (kill the child after this long with
    #                        no output -- "no activity" timeout).
    #   post_exit_timeout -> orphan_timeout  (quiet window after the child is
    #                        reaped before still-open pipes are declared orphaned
    #                        -- the post-exit grace period for descendants that
    #                        keep writing after the parent exits).
    # NOT lifetime_timeout: that caps TOTAL runtime, which would kill any healthy
    # test running longer than post_exit_timeout (15s default). The harness has no
    # absolute-lifetime option, so lifetime_timeout is left at the collector's
    # default (0/disabled). When a timeout is disabled (HARNESS-NO-TIMEOUT, or
    # --no-post-exit-timeout) pass 0 explicitly so the collector waits for EOF
    # rather than falling back to its own 30s orphan default.
    my $orphan_timeout = ($self->use_timeout && $self->post_exit_timeout) ? $self->post_exit_timeout : 0;

    my %common = (
        name               => $self->rel_file,
        is_test            => 1,
        run_uuid           => $self->run->run_id,
        try                => $self->is_try,
        record_transitions => 1,
        recorder           => Test2::Collector::Recorder::Zstd->new(file => $self->events_file),
        child_env          => $self->env_vars,
        chdir              => ($self->ch_dir || undef),
        io_events          => ($self->io_events ? 1 : 0),
        orphan_timeout     => $orphan_timeout,
        ($in_file                                    ? (stdin           => $in_file)            : ()),
        ($self->use_timeout && $self->event_timeout) ? (silence_timeout => $self->event_timeout) : (),
    );

    return Test2::Collector::collect(%common, @target);
}

sub switches_from_env {
    my $self = shift;

    return @{$self->{+SWITCHES_FROM_ENV}} if $self->{+SWITCHES_FROM_ENV};

    return @{$self->{+SWITCHES_FROM_ENV} = []} unless $ENV{HARNESS_PERL_SWITCHES};

    return @{$self->{+SWITCHES_FROM_ENV} = [split /\s+/, $ENV{HARNESS_PERL_SWITCHES}]};
}

my %JSON_SKIP = (
    SETTINGS()         => 1,
    TASK()             => 1,
    RUNNER()           => 1,
    RUN()              => 1,
    CLI_INCLUDES()     => 1,
    CLI_OPTIONS()      => 1,
    ERR_FILE()         => 1,
    EVENTS_FILE()      => 1,
    EXIT()             => 1,
    EXIT_TIME()        => 1,
    IN_FILE()          => 1,
    JOB_DIR()          => 1,
    OUT_FILE()         => 1,
    BAIL_FILE()        => 1,
    RUN_DIR()          => 1,
    TMP_DIR()          => 1,
);

sub TO_JSON {
    my $self = shift;

    my $out = { %{$self->{+TASK}} };

    for my $attr (Test2::Harness2::Util::HashBase::attr_list(blessed($self))) {
        next if $JSON_SKIP{$attr};
        $self->$attr unless defined $self->{$attr};
        $out->{$attr} = $self->{$attr};
    }

    delete $out->{+FORK_CALLBACK};
    delete $out->{+VIA} if ref($out->{+VIA}) eq 'CODE';

    $out->{job_name} //= $out->{job_id};
    $out->{abs_file} = clean_path($self->file);

    return $out;
}

sub run_file  {
    my $self = shift;
    return $self->{+RUN_FILE} //= $self->rel_file;
}

sub rel_file  { File::Spec->abs2rel($_[0]->file) }
sub file      { $_[0]->{+FILE}      //= clean_path($_[0]->{+TASK}->{file}, 0) }
sub err_file  { $_[0]->{+ERR_FILE}  //= clean_path(File::Spec->catfile($_[0]->job_dir, 'stderr')) }
sub out_file  { $_[0]->{+OUT_FILE}  //= clean_path(File::Spec->catfile($_[0]->job_dir, 'stdout')) }
sub bail_file { $_[0]->{+BAIL_FILE} //= clean_path(File::Spec->catfile($_[0]->job_dir, 'bail')) }
sub events_file { $_[0]->{+EVENTS_FILE} //= clean_path(File::Spec->catfile($_[0]->job_dir, 'events.jsonl.zst')) }
sub run_dir   { $_[0]->{+RUN_DIR}   //= clean_path(File::Spec->catdir($_[0]->{+RUNNER}->dir, $_[0]->{+RUN}->run_id)) }

sub bailed_out {
    my $self = shift;

    if(-f $self->bail_file) {
        my $fh = open_file($self->bail_file, '<');
        my $reason = <$fh> || 1;
        return $reason;
    }

    # As of chunk 3 (Test2-Collector swap) the runner no longer writes a stdout
    # file, so the legacy "scan stdout for 'Bail out!'" path has no input. Guard
    # against the missing file so this never dies at runtime. Bail-out is now
    # carried in the events stream (a control facet / harness_final_state halt);
    # re-sourcing bail detection from the events file is a deferred follow-up.
    return "" unless -f $self->out_file;

    my $fh = open_file($self->out_file, '<');
    while (my $line = <$fh>) {
        next unless $line =~ m/^Bail out!\s*(.*)$/;
        return $1 || 1;
    }

    return "";
}

sub verbose { $_[0]->{+VERBOSE} //= $_[0]->{+TASK}->{verbose} // 0 }
sub is_try  { $_[0]->{+IS_TRY}  //= $_[0]->{+TASK}->{is_try}  // 0 }
sub ch_dir  { $_[0]->{+CH_DIR}  //= $_[0]->{+TASK}->{ch_dir}  // '' }
sub unsafe_inc  { $_[0]->{+UNSAFE_INC}  //= $_[0]->{+RUNNER}->unsafe_inc }
sub event_uuids { $_[0]->{+EVENT_UUIDS} //= $_[0]->run->event_uuids }
sub mem_usage   { $_[0]->{+MEM_USAGE}   //= $_[0]->run->mem_usage }

sub io_events { $_[0]->{+IO_EVENTS} //= $_[0]->_fallback(io_events => 1, qw/task run/) }

sub smoke             { $_[0]->{+SMOKE}             //= $_[0]->_fallback(smoke             => 0,     qw/task/) }
sub retry_isolated    { $_[0]->{+RETRY_ISOLATED}    //= $_[0]->_fallback(retry_isolated    => 0,     qw/task run/) }
sub use_timeout       { $_[0]->{+USE_TIMEOUT}       //= $_[0]->_fallback(use_timeout       => 1,     qw/task/) }
sub retry             { $_[0]->{+RETRY}             //= $_[0]->_fallback(retry             => undef, qw/task run/) }
sub event_timeout     { $_[0]->{+EVENT_TIMEOUT}     //= $_[0]->_fallback(event_timeout     => undef, qw/task runner/) }
sub post_exit_timeout { $_[0]->{+POST_EXIT_TIMEOUT} //= $_[0]->_fallback(post_exit_timeout => undef, qw/task runner/) }

sub min_slots { $_[0]->{+MIN_SLOTS} //= $_[0]->_fallback_non_bool(min_slots => 1, qw/task/) }
sub max_slots { $_[0]->{+MAX_SLOTS} //= $_[0]->_fallback_non_bool(max_slots => 1, qw/task/) }

sub args { @{$_[0]->{+ARGS} //= $_[0]->_merge_sources(test_args => qw/task run/)} }
sub load { @{$_[0]->{+LOAD} //= [@{$_[0]->run->load // []}]} }

sub cli_includes {
    my $self = shift;

    # '.' is handled via the PERL_USE_UNSAFE_INC env var set later
    $self->{+CLI_INCLUDES} //= [map { "-I$_" } grep { $_ ne '.' } $self->includes];

    return @{$self->{+CLI_INCLUDES}};
}

sub runner_includes { @{$_[0]->{+RUNNER_INCLUDES} //= [$_[0]->{+RUNNER}->all_libs]} }

sub _merge_sources {
    my $self = shift;
    my ($name, @from) = @_;

    my @vals;
    for my $from (@from) {
        my $source = $self->$from;
        my $val = blessed($source) ? $source->$name : $source->{$name};
        next unless defined $val;
        next unless @$val;
        push @vals => @$val;
    }

    return \@vals;
}

sub _fallback_non_bool {
    my $self = shift;
    my ($name, $default, @from) = @_;

    for my $from (@from) {
        my $source = $self->$from;
        my $val = blessed($source) ? $source->$name : $source->{$name};
        return $val if defined $val;
    }

    return $default;
}

sub _fallback {
    my $self = shift;
    my ($name, $default, @from) = @_;

    my @vals;
    for my $from (@from) {
        my $source = $self->$from;
        my $val = blessed($source) ? $source->$name : $source->{$name};
        push @vals => $val if defined $val;
    }

    return $default unless @vals;

    # If the default is a ref we will just return the first value we found, truthiness check is useless
    return shift @vals if ref $default || !defined($default) || $default !~ m/^(0|1)$/;

    # If the default is true, then we only return true if none of the vals are false
    return !grep { !$_ } @vals if $default;

    # If the default is false, then we return true if any of the valse are true
    return grep { $_ } @vals;
}

sub job_dir {
    my $self = shift;
    return $self->{+JOB_DIR} if $self->{+JOB_DIR};

    my $job_dir = File::Spec->catdir($self->run_dir, $self->{+TASK}->{job_id} . '+' . $self->is_try);
    mkdir($job_dir) or die "$$ $0 Could not create job directory '$job_dir': $!";
    chmod_tmp($job_dir);
    $self->{+JOB_DIR} = $job_dir;
}

sub tmp_dir {
    my $self = shift;

    return $self->{+TMP_DIR} if $self->{+TMP_DIR};

    my $tmp_dir = File::Temp::tempdir("XXXXXX", DIR => $self->runner->tmp_dir);
    chmod_tmp($tmp_dir);

    $self->{+TMP_DIR} = clean_path($tmp_dir);
}

sub in_file {
    my $self = shift;
    return $self->{+IN_FILE} if $self->{+IN_FILE};

    my $task = $self->{+TASK};

    unless ($task->{input}) {
        my $from_run = $self->run->input_file;
        return $self->{+IN_FILE} = $from_run if $from_run;
    }

    my $stdin = File::Spec->catfile($self->job_dir, 'stdin');

    my $content = $task->{input} // $self->run->input // '';
    write_file($stdin, $content);

    return $self->{+IN_FILE} = $stdin;
}

sub use_fork {
    my $self = shift;

    return $self->{+USE_FORK} if defined $self->{+USE_FORK};

    my $task = $self->{+TASK};

    return $self->{+USE_FORK} = 0 unless CAN_REALLY_FORK;
    return $self->{+USE_FORK} = 0 if $task->{binary};
    return $self->{+USE_FORK} = 0 if $task->{non_perl};
    return $self->{+USE_FORK} = 0 if defined($task->{use_fork}) && !$task->{use_fork};
    return $self->{+USE_FORK} = 0 if defined($task->{use_preload}) && !$task->{use_preload};

    # -w switch is ok, otherwise it is a no-go
    return $self->{+USE_FORK} = 0 if grep { !m/\s*-w\s*/ } $self->switches;

    my $runner = $self->{+RUNNER};
    return $self->{+USE_FORK} = 0 unless $runner->use_fork;

    return $self->{+USE_FORK} = 1;
}

sub includes {
    my $self = shift;

    return @{$self->{+INCLUDES}} if $self->{+INCLUDES};

    $self->{+INCLUDES} = [
        process_includes(
            list            => [$self->runner_includes, @{$self->{+SETTINGS}->harness->orig_inc}],
            include_dot     => $self->unsafe_inc,
            include_current => 1,
            clean           => 1,
            $self->ch_dir ? (ch_dir => $self->ch_dir) : (),
        )
    ];

    return @{$self->{+INCLUDES}};
}

sub cli_options {
    my $self = shift;

    # Test2::Formatter::Collector is selected by Test2::Collector in the child
    # (T2_FORMATTER=Collector); io-events is handled via collect(io_events=>).
    return (
        $self->event_uuids ? ('-MTest2::Plugin::UUID')                     : (),
        $self->mem_usage   ? ('-MTest2::Plugin::MemUsage')                 : (),
        (map { @{$_->[1]} ? "-M$_->[0]=" . join(',' => @{$_->[1]}) : "-M$_->[0]" } $self->load_import),
        (map { "-m$_" } $self->load),
    );
}

sub switches {
    my $self = shift;

    return @{$self->{+SWITCHES}} if $self->{+SWITCHES};

    my @switches;

    my %seen;
    for my $s (@{$self->{+TASK}->{switches} // []}) {
        $seen{$s}++;
        $self->{+USE_W_SWITCH} = 1 if $s =~ m/\s*-w\s*/;
        push @switches => $s;
    }

    my %seen2;
    for my $s (@{$self->{+RUNNER}->switches // []}) {
        next if $seen{$s};
        $seen2{$s}++;
        $self->{+USE_W_SWITCH} = 1 if $s =~ m/\s*-w\s*/;
        push @switches => $s;
    }

    for my $s ($self->switches_from_env) {
        next if $seen{$s};
        next if $seen2{$s};
        $self->{+USE_W_SWITCH} = 1 if $s =~ m/\s*-w\s*/;
        push @switches => $s;
    }

    return @{$self->{+SWITCHES} = \@switches};
}

sub prof_file {
    my $self = shift;
    my $file =$self->rel_file;

    $file =~ s{/}{-}g;
    $file =~ s{\.[^\.]+$}{.nytprof}g;

    return $file;
}

sub env_vars {
    my $self = shift;

    return $self->{+ENV_VARS} if $self->{+ENV_VARS};

    my $from_run = $self->run->env_vars;
    my $from_task = $self->{+TASK}->{env_vars};

    my @p5l = ($from_task->{PERL5LIB}, $from_run->{PERL5LIB});
    push @p5l => $self->includes if $self->{+TASK}->{binary} || $self->{+TASK}->{non_perl};
    push @p5l => $ENV{PERL5LIB} if $ENV{PERL5LIB};
    my $p5l = join $Config{path_sep} => grep { defined $_ && $_ ne '.' } @p5l;

    my $verbose = $self->verbose;

    return $self->{+ENV_VARS} = {
        $from_run  ? (%$from_run)  : (),
        $from_task ? (%$from_task) : (),

        # T2_FORMATTER is set to 'Collector' by Test2::Collector inside the test
        # child; the harness no longer selects Test2::Formatter::Stream here.

        $self->{+SETTINGS}->runner->nytprof ? (NYTPROF => "addpid=1:start=begin") : (),

        PERL5LIB            => $p5l,
        PERL_USE_UNSAFE_INC => $self->unsafe_inc,
        TEST2_JOB_DIR       => $self->job_dir,
        TEST2_RUN_DIR       => $self->run_dir,
        TMPDIR              => $self->tmp_dir,
        TEMPDIR             => $self->tmp_dir,
        SYSTEM_TMPDIR       => $self->{+SETTINGS}->harness->orig_tmp,
        SYSTEM_TMPDIR_PERMS => $self->{+SETTINGS}->harness->orig_tmp_perms,

        HARNESS_IS_VERBOSE    => $verbose,
        T2_HARNESS_IS_VERBOSE => $verbose,

        HARNESS_ACTIVE       => 1,
        TEST2_HARNESS_ACTIVE => 1,

        T2_HARNESS_JOB_FILE     => $self->rel_file,
        T2_HARNESS_JOB_NAME     => $self->{+TASK}->{job_name},
        T2_HARNESS_JOB_IS_TRY   => $self->{+IS_TRY}           // 0,
        T2_HARNESS_JOB_DURATION => $self->{+TASK}->{duration} // '',
    };
}

sub load_import {
    my $self = shift;

    return @{$self->{+LOAD_IMPORT}} if $self->{+LOAD_IMPORT};

    my $from_run = $self->run->load_import;

    my @out;
    for my $mod (@{$from_run->{'@'} // []}) {
        push @out => [$mod, $from_run->{$mod} // []];
    }

    return @{$self->{+LOAD_IMPORT} = \@out};
}

sub use_w_switch {
    my $self = shift;
    return $self->{+USE_W_SWITCH} if defined $self->{+USE_W_SWITCH};
    $self->switches;
    return $self->{+USE_W_SWITCH};
}

sub set_exit {
    my $self = shift;
    my ($runner, $exit, $time, @args) = @_;

    # Runner bookkeeping only. The job's exit status is recorded by the
    # collector as a harness_process_exit event in events.jsonl.zst; the
    # harness no longer writes a separate 'exit' file.
    $self->SUPER::set_exit(@_);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Job - Representation of a test job.

=head1 DESCRIPTION

This module takes all the data from a test file queue item, a run, and runner
settings, and mashes them together to figure out what is actually needed to run
a job.

=head1 METHODS

Note, this object subclasses L<Test2::Harness2::IPC::Process>.

=over 4

=item $arrayref = $job->args

Get the arguments for the test either formt he queue item, or from the run.

=item $path = $job->bail_file

Path to the events-file used in case of a bail-out

=item $bool = $job->bailed_out

True if the test job bailed out.

=item $cat $job->category

Process category, always 'job' unless overriden in a subclass.

=item $path = $job->ch_dir

If this job first requires a change in directory before running, this will
return the path.

=item @list = $job->cli_includes

List of includes for a command line launch of this job.

=item @list = $job->cli_options

List of options for a command line launch of this job.

=item $hashref = $job->env_vars

Get environment variables to set when launching this job.

=item $path = $job->out_file

File to which all STDOUT for the job will be written.

=item $path = $job->err_file

File to which all STDERR for the job will be written.

=item $time = $job->event_timeout

Event timeout specification, if any, first from test queue item, then from
runner.

=item $time = $job->post_exit_timeout

Post exit timeout specification, if any, first from test queue item, then from
runner.

=item $bool = $job->event_uuids

Use L<Test2::Plugin::UUID> inside the test.

=item $path = $job->file

Test file the job will be running.

=item $coderef = $job->fork_callback

If the job is to be launched via fork, use this callback.

=item $path = $job->in_file

File containing STDIN to be provided to the test.

=item @list = $job->includes

Paths to add to @INC for the test.

=item $bool = $job->io_events

True if L<Test2::Plugin::IOEvents> should be used.

=item $int = $job->is_try

This starts at 0 and will be incremented for every retry of the job.

=item $path = $job->job_dir

Temporary directory housing all files related to this job when it runs.

=item $uuid = $job->job_id

UUID for this job.

=item @list = $job->load

Modules to load when starting this job.

=item @list = $job->load_import

Modules to load and import when starting this job.

=item $bool = $job->mem_usage

True if the L<Test2::Plugin::MemUsage> plugin should be used.

=item $path = $job->run_file

Usually the same as rel_file, but you can specify an alternative file to
actually run.

=item $path = $job->rel_file

Relative path to the file.

=item $int = $job->retry

How many times the test should be retried if it fails.

=item $bool = $job->retry_isolated

True if the test should be retried in isolation if it fails.

=item $run = $job->run

The L<Test2::Harness2::Runner::Run> instance.

=item $path = $job->run_dir

Path to the temporary directory housing all the data about the run.

=item $runner = $job->runner

The L<Test2::Harness2::Runner> instance.

=item @list = $job->runner_includes

Search path includes provided directly by the runner.

=item $settings = $job->settings

The L<Getopt::Yath::Settings> instance.

=item $bool = $job->smoke

True if the test is a priority smoke test.

=item $hashref = $job->spawn_params

Parameters for C<run_cmd()> in L<Test2::Harness2::Util::IPC> when launching this
job. If the task has a C<resource_skip> set (indicating permanently unavailable
resources), the command will emit TAP to skip the test. When the
C<--fail-on-resource-skip> runner option is enabled, the command will instead
emit a TAP test failure.

=item @list = $job->switches

Command line switches for perl when running this test.

=item $hashref = $job->task

Task data from the queue.

=item $path = $job->tmp_dir

Temp dir created specifically for this job.

=item $bool = $job->unsafe_inc

True if '.' should be added to C<@INC>.

=item $bool = $job->use_fork

True if this job should be launched via fork.

=item $bool = $job->use_timeout

True if this job should timeout due to lack of activity.

=item $bool = $job->use_w_switch

True if the C<-w> switch should be used for this test.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

package App::Yath2;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util::HashBase qw{
    <config
    <settings

    +options

    <_argv <argv_processed <_orig_argv

    <_command_class <_command_name

    <option_state
    <state_env <state_cleared <state_modules
};

use Time::HiRes qw/time/;
use Scalar::Util qw/blessed/;

use Getopt::Yath::Instance;
use Getopt::Yath::Settings;

use App::Yath2::Util qw/find_pfile/;
use Test2::Harness2::Util qw/find_libraries clean_path mod2file/;

use App::Yath2::Options::Debug;
use App::Yath2::Options::PreCommand;

my $APP_PATH = __FILE__;
$APP_PATH =~ s{App\S+Yath2\.pm$}{}g;
$APP_PATH = clean_path($APP_PATH);
sub app_path { $APP_PATH }

sub init {
    my $self = shift;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    my @caller = caller(1);

    $self->{+SETTINGS} //= Getopt::Yath::Settings->new;

    my $harness = $self->{+SETTINGS}->group(harness => 1);
    ${$harness->option_ref(script          => 1)} //= clean_path($caller[1]);
    ${$harness->option_ref(start           => 1)} //= time();
    ${$harness->option_ref(no_scan_plugins => 1)} //= 0;

    $self->{+_ARGV} //= delete($self->{argv}) // [];
    $self->{+_ORIG_ARGV} = [@{$self->{+_ARGV}}];
    $self->{+CONFIG} //= {};
}

sub generate_run_sub ($self, $symbol) {
    my $argv      = $self->process_argv();
    my $settings  = $self->{+SETTINGS};
    my $cmd_class = $self->{+_COMMAND_CLASS};

    return $cmd_class->generate_run_sub($symbol, $argv, $settings, $self->{+_ORIG_ARGV}) if $cmd_class->can('generate_run_sub');

    my $cmd = $cmd_class->new(settings => $settings, args => $argv, orig_args => $self->{+_ORIG_ARGV});

    my $run = sub { $self->run_command($cmd) };

    {
        no strict 'refs';
        *{$symbol} = $run;
    }

    return;
}

sub run_command {
    my $self = shift;
    my ($cmd) = @_;

    my $exit = $cmd->run;

    die "Command '" . $cmd->name() . "' did not return an exit value.\n"
        unless defined $exit;

    return $exit;
}

sub options ($self) {
    return $self->{+OPTIONS} if $self->{+OPTIONS};

    my $options = $self->{+OPTIONS} = Getopt::Yath::Instance->new(
        category_sort_map => {
            'NO CATEGORY - FIX ME' => 99999,
            'Yath Options'         => -100,
            'Plugins'              => -99,
            'Environment'          => -98,
            'Developer'            => -97,
            'Help and Debugging'   => -90,
        },
    );

    $options->include(App::Yath2::Options::Debug->options);
    $options->include(App::Yath2::Options::PreCommand->options);

    return $options if $self->{+SETTINGS}->harness->no_scan_plugins;

    my $option_libs = {
        %{find_libraries('App::Yath2::Plugin::*')},
        %{find_libraries('Test2::Harness2::Runner::Resource::*')},
    };

    for my $lib (sort keys %$option_libs) {
        my $ok  = eval { require $option_libs->{$lib}; 1 };
        my $err = $@;
        unless ($ok) {
            warn "Failed to load module '$option_libs->{$lib}': $err";
            next;
        }

        next unless $lib->can('options');
        my $add = $lib->options or next;

        # Skip anything whose options() does not hand back a
        # Getopt::Yath::Instance, as a safety check.
        next unless blessed($add) && $add->isa('Getopt::Yath::Instance');

        $options->include($add);
    }

    return $options;
}

sub process_argv ($self) {
    return $self->{+_ARGV} if $self->{+ARGV_PROCESSED}++;

    my $settings = $self->{+SETTINGS};

    # Stage 1: global/pre-command options. Config file global ('~') args are
    # parsed first so that real command line arguments override them.
    my @args  = (@{$self->{+CONFIG}->{'~'} // []}, @{$self->{+_ARGV}});
    my $state = $self->_process_global_args(\@args);

    my ($cmd_name, $tail) = $self->_command_from_argv($state);

    my $cmd_class = $self->load_command($cmd_name);
    $self->{+_COMMAND_NAME}  = $cmd_name;
    $self->{+_COMMAND_CLASS} = $cmd_class;

    # Stage 2: command options. Config file command args first (so the
    # command line overrides them), then any unrecognized options that were
    # skipped in stage 1, then everything that followed the command.
    my @cmd_args = (
        @{$self->{+CONFIG}->{$cmd_name} // []},
        @{$state->{skipped} // []},
        @$tail,
    );

    # When --help or --version fired the stage-1 shortcut the debug posts will
    # exit(0) during stage-2 processing, so @{$self->{+_ARGV}} is never
    # populated and any trailing args (e.g. `yath --help test`) are silently
    # lost.  Fix: skip posts during _process_command_args, build @argv first,
    # then replay the posts so they see the correct argv.
    my $replay_posts = $settings->debug->help || $settings->debug->version;

    # Some options (finder via --finder, external plugins via -p+Foo) pull in
    # additional option groups from their trigger. process_args() snapshots the
    # applicable option set once at its start, so those late includes would be
    # invisible to the rest of the same parse and their options rejected. Run a
    # throwaway discovery parse first to fire those includes, then parse for real
    # with the grown option set. See _preload_dynamic_options.
    $self->_preload_dynamic_options(\@cmd_args);

    my $cmd_state = $self->_process_command_args(
        \@cmd_args,
        cmd => $cmd_name,
        $replay_posts ? (skip_posts => 1) : (),
    );
    $self->{+OPTION_STATE} = $cmd_state;

    # Final argv for the command: non-option args, plus any stop token
    # ('--' or '::') and everything after it, preserved for the command to
    # interpret.
    my @argv = @{$cmd_state->{skipped} // []};
    push @argv => $cmd_state->{stop} if defined $cmd_state->{stop};
    push @argv => @{$cmd_state->{remains} // []};

    @{$self->{+_ARGV}} = @argv;

    $self->clear_env();

    $self->_instantiate_plugins();

    # Replay the posts now that @{$self->{+_ARGV}} is fully populated.  The
    # help/version posts exit(0) here, which is intentional.
    if ($replay_posts) {
        my $options = $self->options;
        for my $weight (sort { $a <=> $b } keys %{$options->posts}) {
            for my $set (@{$options->posts->{$weight}}) {
                next if $set->{applicable} && !$set->{applicable}->($set, $options, $settings);
                $set->{callback}->($options, $cmd_state);
            }
        }
    }

    return $self->{+_ARGV};
}

sub _process_args ($self, $args, %params) {
    return $self->options->process_args(
        $args,
        env      => $self->{+STATE_ENV}     //= {},
        cleared  => $self->{+STATE_CLEARED} //= {},
        modules  => $self->{+STATE_MODULES} //= {},
        settings => $self->{+SETTINGS},
        stops    => ['--', '::'],
        %params,
    );
}

sub _process_global_args ($self, $args, %params) {
    # Pass-through unknown options at this stage rather than erroring.
    # Top-level options are intentionally a small set; everything else
    # (renderer, runner, finder, ...) is command-scoped. Letting unknown
    # forms fall through here lets users put e.g. `-v` before the command
    # (`yath -D -v test ...`) and have it bind at command-level parsing.
    # Genuinely invalid options surface a clear, command-specific error
    # later in _process_command_args.
    return $self->_process_args(
        $args,
        %params,

        skip_posts        => 1,
        stop_at_non_opts  => 1,
        skip_invalid_opts => 1,
    );
}

sub _process_command_args ($self, $args, %params) {
    my $cmd = delete $params{cmd} or die "'cmd' arg missing";

    return $self->_process_args(
        $args,
        %params,

        skip_non_opts => 1,

        invalid_opt_callback => sub ($opt, @) {
            print STDERR "\nERROR: '$opt' is not a valid yath or '$cmd' command option.\nSee `yath help $cmd` for available options.\n\n";
            exit 255;
        },
    );
}

sub _preload_dynamic_options ($self, $cmd_args) {
    # process_args() snapshots the applicable options once at its start, so a
    # group pulled in mid-parse by a trigger (--finder's, or -p+Foo's) is unseen
    # by the rest of THAT parse and its options get rejected. This throwaway
    # discovery parse fires those include()s up front; they are idempotent
    # (Getopt::Yath::Instance DEDUP), so the real stage-2 parse re-runs the same
    # triggers harmlessly. A discard settings plus skip_posts/no_set_env suppress
    # every other side effect. Unknown options are skipped here, so the only
    # possible death is a trigger content error (e.g. an unloadable finder) that
    # stage 2 would raise anyway -- let it propagate, don't hide it.
    my $discard = Getopt::Yath::Settings->new(harness => {});

    $self->options->process_args(
        [@$cmd_args],
        settings          => $discard,
        env               => {},
        cleared           => {},
        modules           => {},
        stops             => ['--', '::'],
        skip_posts        => 1,
        skip_non_opts     => 1,
        skip_invalid_opts => 1,
        no_set_env        => 1,
    );

    return;
}

sub command_class {
    my $self = shift;

    $self->process_argv() unless $self->{+_COMMAND_CLASS};

    return $self->{+_COMMAND_CLASS};
}

sub _command_from_argv ($self, $state) {
    my $settings = $self->{+SETTINGS};

    my @args = grep { defined($_) } $state->{stop}, @{$state->{remains} // []};

    # --version (a stage-1 option) resolves to the option-less 'help' command;
    # its post-processing prints and exits before any real command loads.
    return (help => \@args) if $settings->debug->version;

    # --help still resolves a real command when present (so `yath --help test`
    # renders test's help); only bare `yath --help` falls through to 'help'.

    # First bareword that is neither a registered command nor a path; used as a
    # typo'd-command fallback if no real command turns up.
    my $fallback_idx;

    for (my $idx = 0; $idx < @args; $idx++) {
        my $arg = $args[$idx];

        if ($arg =~ m/^-*h(elp)?$/i) {
            splice(@args, $idx, 1);
            return (help => \@args);
        }

        if ($arg eq 'do') {
            splice(@args, $idx, 1);
            last;
        }

        last if $arg eq '::';
        next if $arg =~ m/^-/;

        if ($arg =~ m/\.jsonl(\.bz2|\.gz)?$/) {
            warn "\n** First argument is a log file, defaulting to the 'replay' command **\n\n";
            return (replay => \@args);
        }

        # Nested subcommands: `yath db importer` -> the db-importer command
        # (App::Yath2::Command::db::importer). Prefer the nested command when the
        # combined "$arg-$next" resolves; a bare `yath db` (next is an option,
        # path, or non-subcommand) still falls through to the plain command.
        if ($idx + 1 < @args) {
            my $next = $args[$idx + 1];
            if ($next !~ m/^-/ && $self->load_command("$arg-$next", check_only => 1)) {
                splice(@args, $idx, 2);
                return ("$arg-$next" => \@args);
            }
        }

        # A real command anywhere wins, so a separated value for an unknown
        # option (`--formatter Test2 test`) is not mistaken for the command --
        # 'Test2' is skipped, 'test' is found, and 'Test2' rides along to stage 2.
        if ($self->load_command($arg, check_only => 1)) {
            splice(@args, $idx, 1);
            return ($arg => \@args);
        }

        # Paths fall through to defaults; the first other bareword is a likely
        # typo'd command, remembered for the post-loop fallback.
        next if -f $arg || -d $arg;
        $fallback_idx //= $idx;
    }

    # Surface a remembered bareword as the command (load_command reports it
    # invalid) when no real command was found.
    if (defined $fallback_idx) {
        my $cmd = splice(@args, $fallback_idx, 1);
        return ($cmd => \@args);
    }

    return (help => \@args) if $settings->debug->help;

    if (find_pfile($settings, no_checks => 1)) {
        warn "\n** Persistent runner detected, defaulting to the 'run' command **\n\n";
        return (run => \@args);
    }

    warn "\n** Defaulting to the 'test' command **\n\n";
    return (test => \@args);
}

sub load_command ($self, $cmd_name, %params) {
    # Command names may be nested (e.g. db-importer, client-publish), which live
    # under a Command subdir (db/importer.pm => App::Yath2::Command::db::importer).
    # Map '-' / '/' / '::' separators to the subdir path + class. Top-level
    # command files carry no '-', so this is a no-op for them.
    my @parts     = split m{-|/|::}, $cmd_name;
    my $cmd_class = join('::', 'App::Yath2::Command', @parts);
    my $cmd_file  = join('/',  'App/Yath2/Command',   @parts) . '.pm';

    my $ok  = eval { require $cmd_file; 1 };
    my $err = $@;

    unless ($ok) {
        $err ||= 'unknown error';
        my $not_found = $err =~ m{Can't locate \Q$cmd_file\E in \@INC};

        return undef if $params{check_only} && $not_found;

        die "yath command '$cmd_name' not found. (did you forget to install $cmd_class?)\n"
            if $not_found;

        die $err;
    }

    return $cmd_class if $params{check_only};

    # Only register the command when called on an instance (this method is
    # also used as a class-method utility, ex by the 'help' command).
    if (blessed($self)) {
        # Fold the command's own options into the app instance. The base
        # command class returns undef from options(); the isa guard skips
        # that (and anything not yet a Getopt::Yath::Instance).
        if ($cmd_class->can('options')) {
            my $add = $cmd_class->options;
            $self->options->include($add) if blessed($add) && $add->isa('Getopt::Yath::Instance');
        }

        # Several option post-processing hooks (help banner, workspace
        # cleanup, finder applicability) read this, it MUST be set before
        # the stage 2 parse runs the posts.
        $self->{+SETTINGS}->harness->create_option(command => $cmd_class);
    }

    return $cmd_class;
}

sub _instantiate_plugins ($self) {
    my $harness = $self->{+SETTINGS}->harness;

    my $specs = $harness->check_option('plugins') ? $harness->plugins : undef;
    $specs //= [];

    # The resolved spec strings (Class or Class=arg1,arg2) are stashed below in
    # harness->plugin_specs so the runner can reconstruct the SAME plugin instances
    # (plugin setup/teardown run in the runner). The serialized
    # harness->plugins is bare class names (Plugin::TO_JSON drops any =args), so the
    # specs are the faithful round-trip channel.
    my (%seen, @plugins, @specs);
    for my $spec (@$specs) {
        # Already an instance? Keep it (deduped by class). We only have its class
        # name to carry as a spec (an injected instance has no original arg string).
        if (blessed($spec)) {
            unless ($seen{blessed($spec)}++) {
                push @plugins => $spec;
                push @specs   => blessed($spec);
            }
            next;
        }

        # Specs are normalized to 'Class' or 'Class=arg1,arg2' by the
        # plugins option in App::Yath2::Options::PreCommand.
        my ($class, $args) = split /=/, $spec, 2;
        next if $seen{$class}++;

        my @args = defined($args) ? (split /,/, $args) : ();

        my $file = mod2file($class);
        require $file unless $INC{$file};

        push @plugins => $class->can('new') ? $class->new(@args) : $class;
        push @specs   => $spec;
    }

    # Restore the 1.0 "used_plugins" behavior: any plugin whose option was
    # SET during parse (tracked in STATE_MODULES by Getopt::Yath) is
    # auto-registered, even without an explicit -p spec. This is what makes
    # e.g. --cover-write activate the Cover plugin without -pCover.
    for my $module (keys %{$self->{+STATE_MODULES} // {}}) {
        # Plugin modules are already loaded by options() before parsing, but
        # require defensively first so the isa() guard is robust even if a
        # caller injects an unloaded module name into the parse state.
        my $file = mod2file($module);
        require $file unless $INC{$file};

        next unless $module->isa('App::Yath2::Plugin');
        next if $seen{$module}++;

        push @plugins => $module->can('new') ? $module->new() : $module;
        push @specs   => $module;
    }

    $harness->create_option(plugins      => \@plugins);
    $harness->create_option(plugin_specs => \@specs);

    return \@plugins;
}

sub clear_env {
    # Color is a per-process display choice (decided from each process's own
    # STDOUT), never inherited. Strip it so a TTY parent (or an externally-set
    # value) does not force ANSI color into captured child / nested-yath output.
    # This runs after option processing, so the harness's own color (read into
    # settings already) is unaffected. NOTE: TABLE_TERM_SIZE is intentionally
    # NOT cleared -- Term::Table reads it at render time, so clearing it would
    # break --term-width for the harness itself.
    delete $ENV{YATH_COLOR};
    delete $ENV{CLICOLOR_FORCE};

    delete $ENV{HARNESS_IS_VERBOSE};
    delete $ENV{T2_FORMATTER};
    delete $ENV{T2_HARNESS_FORKED};
    delete $ENV{T2_HARNESS_IS_VERBOSE};
    delete $ENV{T2_HARNESS_JOB_IS_TRY};
    delete $ENV{T2_HARNESS_JOB_NAME};
    delete $ENV{T2_HARNESS_PRELOAD};
    delete $ENV{T2_STREAM_DIR};
    delete $ENV{T2_STREAM_FILE};
    delete $ENV{T2_STREAM_JOB_ID};
    delete $ENV{TEST2_JOB_DIR};
    delete $ENV{TEST2_RUN_DIR};

    # If Test2::API is already loaded then we need to keep these.
    delete $ENV{TEST2_ACTIVE} unless $INC{'Test2/API.pm'};
    delete $ENV{TEST_ACTIVE}  unless $INC{'Test2/API.pm'};
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath2 - Yet Another Test Harness (Test2-Harness) Command Line Interface
(CLI)

=head1 DESCRIPTION

This is the primary documentation for C<yath>, L<App::Yath2>, L<Test2::Harness2>.

The canonical source of up-to-date command options are the help output when
using C<$ yath help> and C<$ yath help COMMAND>.

This document is mainly an overview of C<yath> usage and common recipes.

L<App::Yath2> is an alternative to L<App::Prove>, and L<Test2::Harness2> is an alternative to L<Test::Harness>. It is not designed to
replace L<Test::Harness>/prove. L<Test2::Harness2> is designed to take full
advantage of the rich data L<Test2> can provide. L<Test2::Harness2> is also able to
use non-core modules and provide more functionality than prove can achieve with
its restrictions.

=head1 PLATFORM SUPPORT

L<Test2::Harness2>/L<App::Yath2> is is focused on unix-like platforms. Most
development happens on linux, but bsd, macos, etc should work fine as well.

Patches are welcome for any/all platforms, but the primary author (Chad
'Exodist' Granum) does not directly develop against non-unix platforms.

=head2 WINDOWS

Currently windows is not supported, and it is known that the package will not
install on windows. Patches are be welcome, and it would be great if someone
wanted to take on the windows-support role, but it is not a primary goal for
the project.

=head1 OVERVIEW

To use L<Test2::Harness2>, you use the C<yath> command. Yath will find the tests
(or use the ones you specify) and run them. As it runs, it will output
diagnostic information such as failures. At the end, yath will print a summary
of the test run.

C<yath> can be thought of as a more powerful alternative to C<prove>
(L<Test::Harness>)

=head1 RECIPES

These are common recipes for using C<yath>.

=head2 RUN PROJECT TESTS

    $ yath

Simply running yath with no arguments means "Run all tests for the current
project". Yath will look for tests in C<./t>, C<./t2>, and C<./test.pl> and
run any which are found.

Normally this implies the C<test> command but will instead imply the C<run>
command if a persistent test runner is detected.

=head2 PRELOAD MODULES

Yath has the ability to preload modules. Yath normally forks to start new
tests, so preloading can reduce the time spent loading modules over and over in
each test.

Note that some tests may depend on certain modules not being loaded. In these
cases you can add the C<# HARNESS-NO-PRELOAD> directive to the top of the test
files that cannot use preload.

=head3 SIMPLE PRELOAD

Any module can be preloaded:

    $ yath -PMoose

You can preload as many modules as you want:

    $ yath -PList::Util -PScalar::Util

=head3 COMPLEX PRELOAD

If your preload is a subclass of L<Test2::Harness2::Runner::Preload> then more
complex preload behavior is possible. See those docs for more info.

=head2 LOGGING

=head3 RECORDING A LOG

You can turn on logging with a flag. The filename of the log will be printed at
the end.

    $ yath -L
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl

The event log can be quite large. It can be compressed with bzip2.

    $ yath -B
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2

gzip compression is also supported.

    $ yath -G
    ...
    Wrote log file: test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.gz

C<-B> and C<-G> both imply C<-L>.

=head3 REPLAYING FROM A LOG

You can replay a test run from a log file:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2

This will be significantly faster than the initial run as no tests are actually
being executed. All events are simply read from the log, and processed by the
harness.

You can change display options and limit rendering/processing to specific test
jobs from the run:

    $ yath test-logs/2017-09-12~22:44:34~1505281474~25709.jsonl.bz2 -v [TEST UUID(S)]

Note: This is done using the C<$ yath replay ...> command. The C<replay>
command is implied if the first argument is a log file.

=head2 PER-TEST TIMING DATA

The C<-T> option will cause each test file to report how long it took to run.

    $ yath -T

    ( PASSED )  job  1    t/yath_script.t
    (  TIME  )  job  1    Startup: 0.07692s | Events: 0.01170s | Cleanup: 0.00190s | Total: 0.09052s

=head2 PERSISTENT RUNNER

yath supports starting a yath session that waits for tests to run. This is very
useful when combined with preload.

=head3 STARTING

This starts the server. Many options available to the 'test' command will work
here but not all. See C<$ yath help start> for more info.

    $ yath start

=head3 RUNNING

This will run tests using the persistent runner. By default, it will search for
tests just like the 'test' command. Many options available to the C<test>
command will work for this as well. See C<$ yath help run> for more details.

    $ yath run

=head3 STOPPING

Stopping a persistent runner is easy.

    $ yath stop

=head3 INFORMATIONAL

The C<which> command will tell you which persistent runner will be used. Yath
searches for the persistent runner in the current directory, then searches in
parent directories until it either hits the root directory, or finds the
persistent runner tracking file.

    $ yath which

The C<watch> command will tail the runner's log files.

    $ yath watch

=head3 PRELOAD + PERSISTENT RUNNER

You can use preloads with the C<yath start> command. In this case, yath will
track all the modules pulled in during preload. If any of them change, the
server will reload itself to bring in the changes. Further, modified modules
will be blacklisted so that they are not preloaded on subsequent reloads. This
behavior is useful if you are actively working on a module that is normally
preloaded.

=head2 MAKING YOUR PROJECT ALWAYS USE YATH

    $ yath init

The above command will create C<test.pl>. C<test.pl> is automatically run by
most build utils, in which case only the exit value matters. The generated
C<test.pl> will run C<yath> and execute all tests in the C<./t> and/or C<./t2>
directories. Tests in C<./t> will ALSO be run by prove but tests in C<./t2>
will only be run by yath.

=head2 PROJECT-SPECIFIC YATH CONFIG

You can write a C<.yath.rc> file. The file format is very simple. Create a
C<[COMMAND]> section to start the configuration for a command and then
provide any options normally allowed by it. When C<yath> is run inside your
project, it will use the config specified in the rc file, unless overridden
by command line options.

B<Note:> You can also add pre-command options by placing them at the top of
your config file I<BEFORE> any C<[cmd]> markers.

Comments start with a semi-colon.

Example .yath.rc:

    -pFoo ; Load the 'foo' plugin before dealing with commands.

    [test]
    -B ;Always write a bzip2-compressed log

    [start]
    -PMoose ;Always preload Moose with a persistent runner

This file is normally committed into the project's repo.

=head3 SPECIAL PATH PSEUDO-FUNCTIONS

Sometimes you want to specify files relative to the .yath.rc so that the config
option works from any subdirectory of the project. Other times you may wish to
use a shell expansion. Sometimes you want both!

=over 4

=item rel(path/to/file)

    -I rel(path/to/extra_lib)
    -I=rel(path/to/extra_lib)

This will take the path to C<.yath.rc> and prefix it to the path inside
C<rel(...)>. If for example you have C</project/.yath.rc> then the path would
become C</project/path/to/extra_lib>.

=item glob(path/*/file)

    --default-search glob(subprojects/*/t)
    --default-search=glob(subprojects/*/t)

This will add a C<--default-search $_> for every item found in the glob. This
uses the perl builtin function C<glob()> under the hood.

=item relglob(path/*/file)

    --default-search relglob(subprojects/*/t)
    --default-search=relglob(subprojects/*/t)

Same as C<glob()> except paths are relative to the C<.yath.rc> file.

=back

=head2 PROJECT-SPECIFIC YATH CONFIG USER OVERRIDES

You can add a C<.yath.user.rc> file. Format is the same as the regular
C<.yath.rc> file. This file will be read in addition to the regular config
file. Directives in this file will come AFTER the directives in the primary
config so it may be used to override config.

This file should not normally be committed to the project repo.

=head2 HARNESS DIRECTIVES INSIDE TESTS

C<yath> will recognise a number of directive comments placed near the top of
test files. These directives should be placed after the C<#!> line but
before any real code.

Real code is defined as any line that does not start with use, require, BEGIN, package, or #

=over 4

=item good example 1

    #!/usr/bin/perl
    # HARNESS-NO-FORK

    ...

=item good example 2

    #!/usr/bin/perl
    use strict;
    use warnings;

    # HARNESS-NO-FORK

    ...

=item bad example 1

    #!/usr/bin/perl

    # blah

    # HARNESS-NO-FORK

    ...

=item bad example 2

    #!/usr/bin/perl

    print "hi\n";

    # HARNESS-NO-FORK

    ...

=back

=head3 HARNESS-NO-PRELOAD

    #!/usr/bin/perl
    # HARNESS-NO-PRELOAD

Use this if your test will fail when modules are preloaded. This will tell yath
to start a new perl process to run the script instead of forking with preloaded
modules.

Currently this implies HARNESS-NO-FORK, but that may not always be the case.

=head3 HARNESS-NO-FORK

    #!/usr/bin/perl
    # HARNESS-NO-FORK

Use this if your test file cannot run in a forked process, but instead must be
run directly with a new perl process.

This implies HARNESS-NO-PRELOAD.

=head3 HARNESS-NO-STREAM

C<yath> usually runs tests under L<Test2::Collector>, which uses the
L<Test2::Formatter::Collector> formatter instead of TAP. Some tests depend on
using a TAP formatter. This option will make C<yath> use
L<Test2::Formatter::TAP> or L<Test::Builder::Formatter>.

=head3 HARNESS-NO-IO-EVENTS

C<yath> can be configured to use the L<Test2::Plugin::IOEvents> plugin. This
plugin replaces STDERR and STDOUT in your test with tied handles that fire off
proper L<Test2::Event>'s when they are printed to. Most of the time this is not
an issue, but any fancy tests or modules which do anything with STDERR or
STDOUT other than print may have really messy errors.

B<Note:> This plugin is disabled by default, so you only need this directive if
you enable it globally but need to turn it back off for select tests.

=head3 HARNESS-NO-TIMEOUT

C<yath> will usually kill a test if no events occur within a timeout (default
60 seconds). You can add this directive to tests that are expected to trip the
timeout, but should be allowed to continue.

NOTE: you usually are doing the wrong thing if you need to set this. See:
C<HARNESS-TIMEOUT-EVENT>.

=head3 HARNESS-TIMEOUT-EVENT 60

C<yath> can be told to alter the default event timeout from 60 seconds to another
value. This is the recommended alternative to HARNESS-NO-TIMEOUT

=head3 HARNESS-TIMEOUT-POSTEXIT 15

C<yath> can be told to alter the default POSTEXIT timeout from 15 seconds to another value.

Sometimes a test will fork producing output in the child while the parent is
allowed to exit. In these cases we cannot rely on the original process exit to
tell us when a test is complete. In cases where we have an exit, and partial
output (assertions with no final plan, or a plan that has not been completed)
we wait for a timeout period to see if any additional events come into

=head3 HARNESS-DURATION-LONG

This lets you tell C<yath> that the test file is long-running. This is
primarily used when concurrency is turned on in order to run longer tests
earlier, and concurrently with shorter ones. There is also a C<yath> option to
skip all long tests.

This duration is set automatically if HARNESS-NO-TIMEOUT is set.

=head3 HARNESS-DURATION-MEDIUM

This lets you tell C<yath> that the test is medium.

This is the default duration.

=head3 HARNESS-DURATION-SHORT

This lets you tell C<yath> That the test is short.

=head3 HARNESS-CATEGORY-ISOLATION

This lets you tell C<yath> that the test cannot be run concurrently with other
tests. Yath will hold off and run these tests one at a time after all other
tests.

=head3 HARNESS-CATEGORY-IMMISCIBLE

This lets you tell C<yath> that the test cannot be run concurrently with other
tests of this class. This is helpful when you have multiple tests which would
otherwise have to be run sequentially at the end of the run.

Yath prioritizes running these tests above HARNESS-CATEGORY-LONG.

=head3 HARNESS-CATEGORY-GENERAL

This is the default category.

=head3 HARNESS-CONFLICTS-XXX

This lets you tell C<yath> that no other test of type XXX can be run at the
same time as this one. You are able to set multiple conflict types and C<yath>
will honor them.

XXX can be replaced with any type of your choosing.

NOTE: This directive does not alter the category of your test. You are free
to mark the test with LONG or MEDIUM in addition to this marker.

=head3 HARNESS-JOB-SLOTS 2

=head3 HARNESS-JOB-SLOTS 1 10

Specify a range of job slots needed for the test to run. If set to a single
value then the test will only run if it can have the specified number of slots.
If given a range the test will require at least the lower number of slots, and
use up to the maximum number of slots.

=over 4

=item Example with multiple lines.

    #!/usr/bin/perl
    # DASH and space are split the same way.
    # HARNESS-CONFLICTS-DAEMON
    # HARNESS-CONFLICTS  MYSQL

    ...

=item Or on a single line.

    #!/usr/bin/perl
    # HARNESS-CONFLICTS DAEMON MYSQL

    ...

=back

=head3 HARNESS-RETRY-n

This lets you specify a number (minimum n=1) of retries on test failure
for a specific test. HARNESS-RETRY-1 means a failing test will be run twice
and is equivalent to HARNESS-RETRY.

=head3 HARNESS-NO-RETRY

Use this to avoid this test being retried regardless of your retry settings.

=head1 MODULE DOCS

This section documents the L<App::Yath2> module itself.

=head2 SYNOPSIS

In practice you should never need to write your own yath script, or construct
an L<App::Yath2> instance, or even access themain instance when yath is running.
However some aspects of doing so are documented here for completeness.

A minimum yath script looks like this:

    BEGIN {
        package App::Yath2:Script;

        require Time::HiRes;
        require App::Yath2;
        require Getopt::Yath::Settings;

        my $settings = Getopt::Yath::Settings->new;
        $settings->create_group(
            harness => {
                orig_argv => [@ARGV],
                orig_inc  => [@INC],
                script    => __FILE__,
                start     => Time::HiRes::time(),
                version   => $App::Yath2::VERSION,
            },
        );

        my $app = App::Yath2->new(
            argv    => \@ARGV,
            config  => {},
            settings => $settings,
        );

        $app->generate_run_sub('App::Yath::Script::run');
    }

    exit(App::Yath::Script::run());

It is important that most logic live in a BEGIN block. This is so that
L<goto::file> can be used post-fork to execute a test script.

The actual yath script is significantly more complicated with the following behaviors:

=over 4

=item pre-process essential arguments such as -D and no-scan-plugins

=item re-exec with a different yath script if in developer mode and a local copy is found

=item Parse the yath-rc config files

=item gather and store essential startup information

=back

=head2 METHODS

App::Yath2 does not provide many methods to use externally.

=over 4

=item $app->generate_run_sub($symbol_name)

This tells App::Yath2 to generate a subroutine at the specified symbol name
which can be run and be expected to return an exit value.

=item $lib_path = $app->app_path()

Get the include directory App::Yath2 was loaded from.

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

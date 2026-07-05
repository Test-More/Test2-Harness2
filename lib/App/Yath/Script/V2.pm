package App::Yath::Script::V2;
use strict;
use warnings;

our $VERSION = '2.000000';

# The external App::Yath::Script dispatcher calls these two methods as the
# yath script's public entry points: ->do_begin(%params) from the script's
# BEGIN block, then ->do_runtime() afterwards. We keep both names so that
# contract holds. None of do_begin's work actually needs the BEGIN phase
# anymore -- the yath process is just a command dispatcher now (the preload
# goto-file host runs in the preload tree, and no-preload job launch is a
# plain fork+exec), so do_begin just delegates to plain early-runtime setup.
sub do_begin {
    my $class  = shift;
    return $class->setup(@_);
}

sub do_runtime {
    my $class = shift;
    return _run();
}

# Early-runtime setup that builds the App::Yath2 instance. Ordering matters:
# dev-libs (-D / --dev-lib) must land in @INC *before* we require App::Yath2
# and the command/plugin modules it pulls in, so _pre_parse_dev_libs runs
# (and _realpath_paths cleans the new @INC entries) before _build_app.
sub setup {
    my $class  = shift;
    my %params = @_;

    my $script           = $params{script};
    my $argv             = $params{argv};
    my $config_file      = $params{config};
    my $user_config_file = $params{user_config};

    local $.;

    # Capture the original environment early so it reflects state before we
    # start mutating @INC, @ARGV, or loading modules.
    my %ORIG_SIG  = map { defined($SIG{$_}) ? ($_ => "$SIG{$_}") : () } keys %SIG;
    my @ORIG_ARGV = @$argv;
    my @ORIG_INC  = @INC;

    @ARGV = @$argv;

    my ($config_args, $config, $to_clean) = $class->_parse_config_files($config_file, $user_config_file);
    unshift @ARGV => @$config_args;

    my ($dev_libs, $no_scan_plugins) = $class->_pre_parse_dev_libs();
    unshift @INC => @$dev_libs;

    # Now it is safe/ok to load things.
    require Cwd;
    require File::Spec;

    my $orig_tmp       = File::Spec->tmpdir();
    my $orig_tmp_perms = ((stat($orig_tmp))[2] & 07777);

    $class->_realpath_paths($dev_libs, $config, $to_clean);

    my $app = $class->_build_app(
        script           => $script,
        config           => $config,
        config_file      => $config_file,
        user_config_file => $user_config_file,
        orig_tmp         => $orig_tmp,
        orig_tmp_perms   => $orig_tmp_perms,
        orig_sig         => \%ORIG_SIG,
        orig_argv        => \@ORIG_ARGV,
        orig_inc         => \@ORIG_INC,
        dev_libs         => $dev_libs,
        no_scan_plugins  => $no_scan_plugins,
    );

    # Reset these if we got this far.
    $? = 0;
    $@ = '';

    return $app;
}

# Parse the project and user .yath.rc config files into pre-args (dev-libs and
# --no-scan-plugins, which must be applied before command parsing), per-command
# %CONFIG args, and a @TO_CLEAN list of rel()-derived paths to realpath later.
# Returns (\@config_args, \%config, \@to_clean).
sub _parse_config_files {
    my $class = shift;
    my ($config_file, $user_config_file) = @_;

    my %CONFIG;
    my (@CONFIG_ARGS, @TO_CLEAN);

    for my $file ($config_file, $user_config_file) {
        next unless $file && -f $file;

        my $cmd;
        open(my $fh, '<', $file) or die "Could not open config file '$file' for reading: $!";
        while (my $line = <$fh>) {
            chomp($line);
            if ($line =~ m/^\[(.*?)\]\s*(?:;.*)?$/) { $cmd = $1; next; }
            $line =~ s/;.*$//g;
            $line =~ s/^\s*//g;
            $line =~ s/\s*$//g;
            next unless length($line);

            my ($key, $eq, $val);
            if ($line =~ m/^(-\S)((?:rel|glob|relglob)\(.*\))$/) {    # Handle things like -Irel(...)
                $key = $1;
                $eq  = '';
                $val = $2;
            }
            else {
                ($key, $eq, $val) = split /(=|\s+)/, $line, 2;        # Covers most cases
            }

            my $is_pre;
            if ($key =~ m/^-D/ || $key eq '--dev-lib') {
                $eq     = '=' if $val;
                $is_pre = 1;
            }

            if ($key eq '--no-scan-plugins') {
                $is_pre = 1;
            }

            my $need_to_clean;
            if ($val && $val =~ s/(^|=)\s*rel\(\s*//) {
                die "Syntax error in $file line $.: Expected ')'\n" unless $val =~ s/\s*\)$//;
                my $path = $file;
                $path =~ s{[^/]*$}{}g;
                $val           = "${path}${val}";
                $need_to_clean = 1;
            }

            my @all;

            if ($val && $val =~ s/(^|=)\s*(rel)?glob\(\s*//) {
                my $rel = $2;

                die "Syntax error in $file line $.: Expected ')'\n" unless $val =~ s/\s*\)$//;

                my $path = '';
                if ($rel) {
                    $path = $file;
                    $path =~ s{[^/]*$}{}g;
                }

                # Avoid loading File::Glob in this process by shelling out to
                # a child perl. Use list-form open (no shell) so a pattern with
                # a quote or space cannot break/kill a subshell, and wrap the
                # pattern in double quotes so perl's csh-style glob treats an
                # embedded space as a literal rather than a separator.
                my $pattern = "${path}${val}";
                my @vals;
                if (open(my $p, '-|', $^X, '-e', 'print join "\n", glob($ARGV[0])', qq{"$pattern"})) {
                    @vals = <$p>;
                    chomp(@vals);
                    unless (close($p)) {
                        my $why = $! ? "$!" : "child exited " . ($? >> 8);
                        warn "Could not expand glob for '$pattern' in $file line $.: $why\n";
                    }
                }
                else {
                    warn "Could not fork to expand glob for '$pattern' in $file line $.: $!\n";
                }
                @all = map { [$key, $eq, $_, 1] } @vals;
            }
            else {
                @all = ([$key, $eq, $val, $need_to_clean]);
            }

            for my $set (@all) {
                my ($key, $eq, $val, $need_to_clean) = @$set;
                $eq //= '';

                my @parts = $eq eq '=' ? ("${key}${eq}${val}") : (grep { defined $_ } $key, $val);

                if ($is_pre) {
                    push @CONFIG_ARGS => @parts;
                }
                else {
                    $cmd //= '~';
                    push @{$CONFIG{$cmd}} => @parts;
                    push @TO_CLEAN        => [$cmd, $#{$CONFIG{$cmd}}, $key, $eq, $val] if $need_to_clean;
                }
            }
        }
        close($fh);
    }

    return (\@CONFIG_ARGS, \%CONFIG, \@TO_CLEAN);
}

# Pull the -D / --dev-lib and --no-scan-plugins flags out of @ARGV before the
# real command parser runs. Consumes those flags (leaving the rest in @ARGV)
# and returns (\@dev_libs, $no_scan_plugins). The caller prepends @dev_libs to
# @INC so they take effect before any command/plugin modules load.
sub _pre_parse_dev_libs {
    my $class = shift;

    my $no_plugins;
    my (@libs, %done, @args);
    while (@ARGV) {
        my $arg = shift @ARGV;

        if ($arg eq '--' || $arg eq '::') {
            push @args => $arg;
            last;
        }

        if ($arg eq '--no-dev-lib') {
            @libs = ();
            %done = ();
            next;
        }

        if ($arg =~ m{^(?:(?:-D=?|--dev-lib=)(.*)|--dev-lib)$}) {
            my @add = $1 ? ($1) : ();
            @add = ('lib', 'blib/lib', 'blib/arch') unless @add;

            push @libs => grep { !$done{$_}++ } @add;
            next;
        }

        if ($arg eq '--no-scan-plugins') {
            $no_plugins = 1;
            next;
        }

        push @args => $arg;
    }
    @ARGV = (@args, @ARGV);

    return (\@libs, $no_plugins);
}

# Resolve the dev-lib @INC entries and any rel()-derived %CONFIG values to
# absolute, symlink-resolved paths. Mutates @INC, @$dev_libs, and %$config in
# place. Must run after Cwd/File::Spec are loaded.
sub _realpath_paths {
    my $class = shift;
    my ($dev_libs, $config, $to_clean) = @_;

    return unless @$dev_libs || @$to_clean;

    for (my $i = 0; $i < @$dev_libs; $i++) {
        $dev_libs->[$i] = $INC[$i] = Cwd::realpath($INC[$i]) // File::Spec->rel2abs($INC[$i]);
    }

    for my $clean (@$to_clean) {
        my ($cmd, $idx, $key, $eq, $val) = @$clean;
        $val = Cwd::realpath($val) // File::Spec->rel2abs($val);

        if ($eq eq '=') {
            $config->{$cmd}->[$idx] = "${key}${eq}${val}";
        }
        else {
            $config->{$cmd}->[$idx] = $val;
        }
    }
}

# Build and return the App::Yath2 instance from the parsed config, remaining
# @ARGV, captured original environment, and dev-lib info. Wires the generated
# run sub into this package's _run symbol for do_runtime to invoke.
sub _build_app {
    my $class  = shift;
    my %params = @_;

    my $config = $params{config};

    require App::Yath2;
    require Time::HiRes;
    require Getopt::Yath::Settings;

    my %mixin = (config_file => '', user_config_file => '');
    for my $key (qw/config_file user_config_file/) {
        my $file = $params{$key} or next;
        $mixin{$key} = Cwd::realpath($file) // File::Spec->rel2abs($file);
    }

    my $settings = Getopt::Yath::Settings->new;
    $settings->create_group(
        harness => {
            orig_tmp        => $params{orig_tmp},
            orig_tmp_perms  => $params{orig_tmp_perms},
            orig_sig        => $params{orig_sig},
            orig_argv       => $params{orig_argv},
            orig_inc        => $params{orig_inc},
            script          => $params{script},
            no_scan_plugins => $params{no_scan_plugins},
            dev_libs        => $params{dev_libs},
            start           => Time::HiRes::time(),
            version         => $App::Yath2::VERSION,
            cwd             => Cwd::getcwd(),
            %mixin,
        },
    );

    my $app = App::Yath2->new(
        argv     => \@ARGV,
        config   => $config,
        settings => $settings,
    );

    $app->generate_run_sub('App::Yath::Script::V2::_run');

    return $app;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script::V2 - V2 (2.0) yath script handler for Test2::Harness2

=head1 DESCRIPTION

This is the V2 script handler for the 2.0 L<Test2::Harness2>. The external
L<App::Yath::Script> dispatcher loads it as C<App::Yath::Script::V2> and
delegates to it. It is selected when the resolved version is 2, in priority
order: an explicit C<V2> / C<v2> as the first command-line argument; a versioned
C<.yath.V2.rc> / C<.yath.v2.rc> file (or a plain C<.yath.rc> symlink pointing at
one) found while walking up the parent directories; a local
C<./lib/App/Yath/Script/V2.pm> checkout; or, when no version is otherwise
specified, V2 being the highest installed C<App::Yath::Script::V#> module.

This module contains the logic that was previously embedded directly in the
C<scripts/yath> script of L<Test2::Harness2>.

=head1 METHODS

=over 4

=item $app = $class->do_begin(%params)

=item $app = $class->setup(%params)

C<do_begin> is the entry point the L<App::Yath::Script> dispatcher calls from
the C<yath> script's C<BEGIN> block; it simply delegates to C<setup>. The work
itself runs as plain early-runtime setup and does not depend on the C<BEGIN>
phase. It parses configuration files, processes C<-D> and
C<--no-scan-plugins> arguments, sets up C<@INC> (dev-libs land before the
command and plugin modules load), captures the original environment, and
builds the L<App::Yath2> instance.

Parameters:

=over 4

=item script => $path

Path to the executing script.

=item argv => \@argv

Original command line arguments.

=item config => $path

Path to the C<.yath.rc> file, or C<undef>.

=item user_config => $path

Path to the C<.yath.user.rc> file, or C<undef>.

=back

=item $exit = $class->do_runtime()

Called after C<BEGIN>. Executes the yath command and returns the exit code.

=back

=head1 PRIVATE METHODS

=over 4

=item ($config_args, $config, $to_clean) = $class->_parse_config_files($config_file, $user_config_file)

Parse the C<.yath.rc> / C<.yath.user.rc> files into pre-args, per-command
config, and a list of paths to realpath later.

=item ($dev_libs, $no_scan_plugins) = $class->_pre_parse_dev_libs()

Consume C<-D> / C<--dev-lib> / C<--no-scan-plugins> from C<@ARGV>, returning the
dev-lib paths and the no-scan-plugins flag.

=item $class->_realpath_paths($dev_libs, $config, $to_clean)

Resolve dev-lib and rel()-derived config paths to absolute, symlink-resolved
form in place.

=item $app = $class->_build_app(%params)

Construct the L<App::Yath2> instance and wire up the run sub.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

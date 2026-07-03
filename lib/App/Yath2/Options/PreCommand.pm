package App::Yath2::Options::PreCommand;
use v5.38;

our $VERSION = '2.000000';

use App::Yath2::Util qw/find_runner_link/;
use Test2::Harness2::Util qw/mod2file fqmod clean_path/;

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::PreCommand - Options for yath before a command is specified.

=head1 DESCRIPTION

This is where many pre-command options are defined, including plugin loading,
developer library paths, project identity, and persistence configuration.

=head1 PROVIDED OPTIONS

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

Where to find the persistent runner discovery symlink (a link to the runner's socket). The default is /{system-tempdir}/.project-yath-runner.sock. If no project is specified it falls back to the current directory; if the current directory is not writable it defaults to the system temp dir, which limits you to one persistent runner per project on your system.


=item --project ARG

=item --project=ARG

=item --project-name ARG

=item --project-name=ARG

=item --no-project

This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file. This is necessary for a persistent runner.


=back

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


=cut

option_group {group => 'harness', category => 'Yath Options'} => sub {

    # -------------------------------------------------------------------------
    # Plugins
    # -------------------------------------------------------------------------

    option plugins => (
        type  => 'List',
        short => 'p',
        alt   => ['plugin'],

        category       => 'Plugins',
        long_examples  => [' PLUGIN', ' +App::Yath2::Plugin::PLUGIN', ' PLUGIN=arg1,arg2,...'],
        short_examples => ['PLUGIN'],
        description    => 'Load a yath plugin.',

        # Normalize: fully-qualify the class part; preserve any =args suffix.
        normalize => \&normalize_plugin,

        # Trigger: require the plugin module and pull in its options.
        # We do this manually (instead of mod_adds_options) so we can split
        # the class name from any =args suffix before calling mod2file().
        # Note: a plugin's options() might not return a Getopt::Yath::Instance.
        # We guard against that by only calling include() when the returned
        # object is a Getopt::Yath::Instance.
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';

            for my $spec (@{$params{val}}) {
                my ($class) = split /=/, $spec, 2;

                my $file = mod2file($class);
                my $ok   = eval { require $file; 1 };
                my $err  = $@;
                die "Failed to load plugin '$class': $err" unless $ok;

                next unless $class->can('options');
                my $plugin_opts = $class->options;
                next unless ref($plugin_opts) && $plugin_opts->isa('Getopt::Yath::Instance');
                $params{options}->include($plugin_opts);
            }
        },
    );

    option no_scan_plugins => (
        type        => 'Bool',
        category    => 'Plugins',
        description => 'Normally yath scans for and loads all App::Yath2::Plugin::* modules in order to bring in command-line options they may provide. This flag will disable that. This is useful if you have a naughty plugin that is loading other modules when it should not.',
    );

    # -------------------------------------------------------------------------
    # Environment
    # -------------------------------------------------------------------------

    option project => (
        type        => 'Scalar',
        alt         => ['project-name'],
        category    => 'Environment',
        description => 'This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file. This is necessary for a persistent runner.',
    );

    option persist_dir => (
        type        => 'Scalar',
        category    => 'Environment',
        normalize   => \&clean_path,
        description => 'Where to find persistence files.',
    );

    option persist_file => (
        type        => 'Scalar',
        category    => 'Environment',
        alt         => ['pfile'],
        normalize   => \&clean_path,
        description => "Where to find the persistent runner discovery symlink (a link to the runner's socket). The default is /{system-tempdir}/.project-yath-runner.sock. If no project is specified it falls back to the current directory; if the current directory is not writable it defaults to the system temp dir, which limits you to one persistent runner per project on your system.",
    );

    # -------------------------------------------------------------------------
    # Developer
    # -------------------------------------------------------------------------

    option dev_libs => (
        type  => 'AutoPathList',
        short => 'D',
        name  => 'dev-lib',

        category       => 'Developer',
        long_examples  => ['', '=lib'],
        short_examples => ['', '=lib', 'lib'],

        normalize => \&clean_path,

        autofill => sub {
            map { clean_path($_) } 'lib', 'blib/lib', 'blib/arch';
        },

        description => 'Add paths to @INC before loading ANYTHING. This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.',

        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';

            my $ref = $params{ref};

            # Build a set of already-known paths from the current list.
            my %seen = map { $_ => 1 } (defined($$ref) ? @{$$ref} : ());

            # Keep only genuinely new paths.
            my @new = grep { !$seen{$_}++ } @{$params{val}};

            # Clear val to prevent add_value from pushing duplicates.
            # On the early-return path this discards the duplicate entries;
            # on the normal path we replace with the de-duped list below.
            @{$params{val}} = ();
            return unless @new;

            warn <<"            EOT" for @new;
dev-lib '$_' added to \@INC late, it is possible some yath libraries were already loaded from other paths.
(Maybe you need to move the -D or --dev-lib argument(s) to be earlier in your command line or config file?)
            EOT

            unshift @INC => @new;

            # Replace val with only the new (de-duped) paths so add_value
            # does not push duplicates onto the stored list.
            @{$params{val}} = @new;
        },
    );
};

option_post_process 0 => sub ($options, $state) {
    my $settings = $state->{settings};

    return if defined $settings->harness->persist_file;

    # persist_file is now the discovery SYMLINK path (a link to runner.socket), not
    # a JSON metadata file. Vivify the path to use without creating it here; `yath
    # start` publishes the symlink, and the runner's orphan guard tests -e on it.
    $settings->harness->create_option(persist_file => find_runner_link($settings, vivify => 1));
};

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Fully-qualify the class portion of a plugin spec, leaving any =args suffix
# intact.  Input examples:
#   'Git'                   -> 'App::Yath2::Plugin::Git'
#   '+App::Yath2::Plugin::Git'  -> 'App::Yath2::Plugin::Git'
#   'Git=arg1,arg2'         -> 'App::Yath2::Plugin::Git=arg1,arg2'
sub normalize_plugin ($raw) {
    my ($class, $args) = split /=/, $raw, 2;

    # fqmod($prefix, $name): prepends "App::Yath2::Plugin::" unless name
    # starts with '+', in which case the leading '+' is stripped and the
    # remainder is used as-is.
    $class = fqmod('App::Yath2::Plugin', $class);

    return defined($args) ? "$class=$args" : $class;
}

1;

__END__

=pod

=encoding UTF-8

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

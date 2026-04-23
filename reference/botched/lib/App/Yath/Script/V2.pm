package App::Yath::Script::V2;
use strict;
use warnings;

our $VERSION = '2.000012';

use Cwd;
use File::Spec;
use Time::HiRes qw/time/;
use Test2::Harness2::Util qw/find_in_updir clean_path/;

my %BEGIN_PARAMS;

sub do_begin {
    my $class  = shift;
    my %params = @_;

    %BEGIN_PARAMS = %params;
}

sub do_runtime {
    my $class = shift;

    my $script = $BEGIN_PARAMS{script};
    my $argv   = $BEGIN_PARAMS{argv};

    return $class->run($script, $argv);
}

sub run {
    my ($script, $argv);

    if (@_ == 3) {
        # class method: V2->run($script, $argv)
        (undef, $script, $argv) = @_;
    }
    elsif (@_ == 2) {
        # function call: run($script, $argv)
        ($script, $argv) = @_;
    }
    else {
        die "Usage: App::Yath::Script::V2->run(\$script, \$argv)\n";
    }

    $argv //= [];

    $script = clean_path($script);
    $ENV{YATH_SCRIPT} //= $script;

    # Version check: only if App::Yath2 is already loaded
    if (defined $App::Yath2::VERSION) {
        my $v2_version  = $VERSION;
        my $app_version = $App::Yath2::VERSION;
        die "App::Yath::Script::V2 version ($v2_version) does not match App::Yath2 version ($app_version)\n"
            unless $v2_version == $app_version;
    }

    my $settings_data = args_to_settings_data($script, $argv);

    # NOTE: Full execution (creating App::Yath2 instance) is stubbed here
    # because App::Yath2 doesn't exist yet. Return the settings data for now.
    return $settings_data;
}

sub args_to_settings_data {
    my ($script, $argv) = @_;

    my $orig_argv      = [@$argv];
    my $orig_tmp       = File::Spec->tmpdir();
    my $orig_tmp_perms = ((stat($orig_tmp))[2] & 07777);
    my $orig_inc       = [@INC];

    my $config_file      = find_in_updir('.yath.rc');
    my $user_config_file = find_in_updir('.yath.user.rc');

    my $base_file = $config_file || $user_config_file;
    unless ($base_file) {
        for my $scm ('.git', '.svn', '.cvs') {
            $base_file = find_in_updir($scm);
            last if $base_file;
        }
    }

    my $cwd = clean_path(Cwd::getcwd());

    my $base_dir;
    if ($base_file) {
        my ($v, @d) = File::Spec->splitpath($base_file);
        pop @d;
        $base_dir = clean_path(File::Spec->catpath($v, @d));
    }
    else {
        $base_dir = $cwd;
    }

    $ENV{SYSTEM_TMPDIR} = $orig_tmp;

    return {
        yath => {
            script => $script,

            script_version => $VERSION,

            config_file      => $config_file      // '',
            user_config_file => $user_config_file // '',

            base_dir  => $base_dir,
            new_argv  => $argv,
            orig_argv => $orig_argv,
            orig_inc  => $orig_inc,
            orig_tmp  => $orig_tmp,

            orig_tmp_perms => $orig_tmp_perms,

            cwd   => $cwd,
            start => time(),
        },
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Script::V2 - V2 script handler for Test2::Harness

=head1 DESCRIPTION

This module implements the C<App::Yath::Script::V{X}> interface for
L<Test2::Harness> version 2. It is loaded by L<App::Yath::Script> (from
L<App::Yath::Script|App-Yath-Script>) when a project's C<.yath.rc> contains a
C<# V2> marker, or when V2 is the highest installed version.

=head1 METHODS

=over 4

=item $class->do_begin(%params)

Called during the C<BEGIN> phase by C<App::Yath::Script>. Stores the
parameters for use during runtime.

Parameters: C<script>, C<argv>, C<config>, C<user_config>.

=item $exit = $class->do_runtime()

Called at runtime by C<App::Yath::Script>. Builds settings data and
(when App::Yath2 is available) creates an L<App::Yath2> instance and
runs it. Returns the exit code or settings data hashref (partial stub).

=item $exit = $class->run($script, $argv)

Standalone entry point that can be called directly without going through the
C<do_begin>/C<do_runtime> lifecycle.

=item $hashref = args_to_settings_data($script, $argv)

Collects configuration state (INC snapshot, tmpdir, config files, cwd)
and returns a structured hashref for building settings.

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

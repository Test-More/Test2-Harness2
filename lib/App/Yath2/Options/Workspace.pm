package App::Yath2::Options::Workspace;
use v5.38;

our $VERSION = '2.000000';

use File::Spec();
use File::Path qw/remove_tree/;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util qw/clean_path chmod_tmp/;

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Workspace - Options for specifying the yath work dir.

=head1 DESCRIPTION

Options regarding the yath working directory.

=head1 PROVIDED OPTIONS

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


=cut

option_group {group => 'workspace', category => "Workspace Options"} => sub {
    option tmp_dir => (
        type          => 'Scalar',
        short         => 't',
        alt           => ['tmpdir', 'tmp-dir'],
        description   => 'Use a specific temp directory (Default: use system temp dir)',
        from_env_vars => [qw/T2_HARNESS_TEMP_DIR YATH_TEMP_DIR TMPDIR TEMPDIR TMP_DIR TEMP_DIR/],
        default       => sub { File::Spec->tmpdir },
    );

    option workdir => (
        type           => 'Scalar',
        short          => 'w',
        description    => 'Set the work directory (Default: new temp directory)',
        from_env_vars  => [qw/T2_WORKDIR YATH_WORKDIR/],
        clear_env_vars => [qw/T2_WORKDIR YATH_WORKDIR/],
        normalize      => \&clean_path,
    );

    option clear => (
        type        => 'Bool',
        short       => 'C',
        description => 'Clear the work directory if it is not already empty',
    );
};

option_post_process 0 => sub ($options, $state) {
    my $settings = $state->{settings};

    if (my $workdir = $settings->workspace->workdir) {
        if (-d $workdir) {
            remove_tree($workdir, {safe => 1, keep_root => 1}) if $settings->workspace->clear;
        }
        else {
            mkdir($workdir) or die "Could not create workdir: $!";
            chmod_tmp($workdir);
        }

        return;
    }

    my $template = join '-' => ("yath", $$, "XXXXXX");

    # The command class is recorded in settings->harness->command by
    # App::Yath2->load_command() before the command-stage parse runs the
    # posts. Getopt::Yath's parse state has no 'command' key, but keep it
    # as a fallback for direct callers.
    my $command = $settings->maybe(harness => 'command') // $state->{command};

    my $tmpdir = tempdir(
        $template,
        DIR     => $settings->workspace->tmp_dir,
        CLEANUP => !($settings->debug->keep_dirs || ($command && $command->always_keep_dir)),
    );
    chmod_tmp($tmpdir);

    $settings->workspace->create_option(workdir => $tmpdir);
};

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

package Test2::Harness2::Runner::Spawn;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Runner::Job';
use Test2::Harness2::Util::HashBase qw{
    +spawn_fds
};

sub init {
    my $self = shift;

    $self->{+RUN} //= Test2::Harness2::Runner::Spawn::Run->new();
}

# The command's real STDIN/STDOUT/STDERR are passed to the spawn supervisor over
# SCM_RIGHTS and handed to this job (raw fd numbers); the script child dup2s them
# onto 0/1/2 (JobLauncher::_install_spawn_fds). There are no job IO files and no
# /proc proxy -- the child reads/writes the user's real terminal directly.
sub spawn_fds     { $_[0]->{+SPAWN_FDS} }
sub set_spawn_fds { $_[0]->{+SPAWN_FDS} = $_[1] }

sub out_file { undef }
sub err_file { undef }
sub in_file  { undef }

# The host launch (Test2::Harness2::Preload::launch) goto::file's run_file after
# chdir'ing into ch_dir (the command's cwd). The command passes an ABSOLUTE script
# path, so resolve it absolutely -- it opens correctly regardless of the cwd.
sub run_file { $_[0]->file }

sub args { @{$_[0]->{+TASK}->{args} //= []} }

sub job_dir { "" }
sub run_dir { "" }

# A spawned script OUTLIVES the harness (it is detached -- ARCHITECTURE.md §4.8),
# but `yath stop` / `yath kill` deletes the workdir, which is where a normal job's
# tmp_dir lives. If the spawn inherited a workdir-scoped TMPDIR/TEMPDIR, a later
# File::Temp call in the still-running script would fail ENOENT with no visible
# link back to yath. Point it at the SYSTEM tmpdir instead (the same path
# SYSTEM_TMPDIR already computes), which yath never removes.
sub tmp_dir { $_[0]->{+SETTINGS}->harness->orig_tmp }

# A spawned script is NOT a test running under the harness, so it must not carry
# the harness-active markers or a test job dir (a spawn has no job_dir anyway).
# Otherwise harness-aware code in the spawned program would wrongly believe it is
# running under yath.
sub env_vars {
    my $self = shift;

    return $self->{+ENV_VARS} if $self->{+ENV_VARS};

    my $env = $self->SUPER::env_vars;
    delete @{$env}{qw/HARNESS_ACTIVE TEST2_HARNESS_ACTIVE TEST2_JOB_DIR/};

    return $env;
}

sub use_stream   { 0 }
sub event_uuids  { 0 }
sub mem_usage    { 0 }
sub io_events    { 0 }

# These return lists
sub load_import { }
sub load        { }

package Test2::Harness2::Runner::Spawn::Run;

sub new { bless {}, shift };

sub env_vars { {} }

sub AUTOLOAD { }

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Spawn - Minimal job class used for spawning processes

=head1 DESCRIPTION

Do not use this directly...

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

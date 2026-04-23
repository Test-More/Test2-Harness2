package Test2::Harness2::Workspace;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/confess/;
use File::Spec;
use File::Path qw/make_path remove_tree/;
use File::Temp qw/tempdir/;

# '+' prefix: constant for the hash key, but no reader/writer generated
# We provide cleanup() ourselves since it is both attribute and action.
use Test2::Harness2::Util::HashBase qw{
    root
    log_dir
    ipcm_dir
    tmp_dir
    base_tmp
    +cleanup
};

sub init {
    my $self = shift;

    $self->{+BASE_TMP} //= File::Spec->tmpdir;
    $self->{+CLEANUP}  //= 0;

    my $root = tempdir(
        "yath2-$$-XXXXXX",
        DIR     => $self->{+BASE_TMP},
        CLEANUP => 0,
    );

    $self->{+ROOT} = $root;

    my $log_dir  = File::Spec->catdir($root, 'logs');
    my $ipcm_dir = File::Spec->catdir($root, 'ipcm');
    my $tmp_dir  = File::Spec->catdir($root, 'tmp');

    make_path($log_dir, $ipcm_dir, $tmp_dir)
        or confess "Failed to create workspace subdirectories under '$root'";

    $self->{+LOG_DIR}  = $log_dir;
    $self->{+IPCM_DIR} = $ipcm_dir;
    $self->{+TMP_DIR}  = $tmp_dir;

    return;
}

sub cleanup {
    my $self = shift;

    # Called with no args: remove the root directory tree (action).
    # The attribute value is accessed via $self->{+CLEANUP}.
    my $root = $self->{+ROOT} or return;
    remove_tree($root, {safe => 1});
    return;
}

sub run_log_dir {
    my ($self, $run_uuid) = @_;

    confess "run_uuid is required" unless defined $run_uuid;

    my $dir = File::Spec->catdir($self->{+LOG_DIR}, "run_$run_uuid");

    unless (-d $dir) {
        make_path($dir)
            or confess "Failed to create run log dir '$dir'";
    }

    return $dir;
}

sub service_log_path {
    my ($self, $name, $pid) = @_;

    confess "name is required" unless defined $name;
    confess "pid is required"  unless defined $pid;

    return File::Spec->catfile($self->{+LOG_DIR}, "${name}_${pid}.log");
}

sub test_log_path {
    my ($self, $run_uuid, $exec_uuid) = @_;

    confess "run_uuid is required"  unless defined $run_uuid;
    confess "exec_uuid is required" unless defined $exec_uuid;

    my $run_dir = File::Spec->catdir($self->{+LOG_DIR}, "run_$run_uuid");

    confess "run log dir '$run_dir' does not exist; call run_log_dir() first"
        unless -d $run_dir;

    return File::Spec->catfile($run_dir, "$exec_uuid.jsonl");
}

sub DESTROY {
    my $self = shift;
    $self->cleanup() if $self->{+CLEANUP};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Workspace - Manages the temp directory structure for a yath2 run.

=head1 SYNOPSIS

    use Test2::Harness2::Workspace;

    my $ws = Test2::Harness2::Workspace->new(
        base_tmp => '/tmp',
        cleanup  => 1,
    );

    my $run_dir  = $ws->run_log_dir('some-run-uuid');
    my $svc_log  = $ws->service_log_path('renderer', $$);
    my $test_log = $ws->test_log_path('some-run-uuid', 'some-exec-uuid');

    $ws->cleanup();

=head1 DESCRIPTION

Creates a temporary directory tree under C<base_tmp> (defaults to
C<File::Spec-E<gt>tmpdir>) for use during a yath2 run. The root directory is
created via L<File::Temp/tempdir> with the pattern C<yath2-$$-XXXXXX>.

Subdirectories created on C<init>:

=over 4

=item C<logs/>  — per-run and per-service log files

=item C<ipcm/>  — IPC manager socket / state files

=item C<tmp/>   — scratch space for test processes

=back

=head1 ATTRIBUTES

=over 4

=item root

Path to the root workspace directory (set by C<init>).

=item log_dir

Path to C<$root/logs/>.

=item ipcm_dir

Path to C<$root/ipcm/>.

=item tmp_dir

Path to C<$root/tmp/>.

=item base_tmp

Base directory under which the root is created. Defaults to
C<File::Spec-E<gt>tmpdir>.

=item cleanup (hash key only)

Boolean stored as C<$self-E<gt>{+CLEANUP}>. When true, C<DESTROY> will call
C<cleanup()> automatically. Defaults to 0.

=back

=head1 METHODS

=over 4

=item $ws = Test2::Harness2::Workspace->new(%params)

Constructor (provided by L<Test2::Harness2::Util::HashBase>). Accepts optional
C<base_tmp> and C<cleanup> parameters, then calls C<init()>.

=item $ws->init()

Creates the root tempdir and the C<logs/>, C<ipcm/>, and C<tmp/>
subdirectories. Called automatically by C<new>.

=item $path = $ws->run_log_dir($run_uuid)

Returns the path C<$root/logs/run_$run_uuid/>, creating it if it does not yet
exist.

=item $path = $ws->service_log_path($name, $pid)

Returns C<$root/logs/${name}_${pid}.log>. Does B<not> create the file.

=item $path = $ws->test_log_path($run_uuid, $exec_uuid)

Returns C<$root/logs/run_$run_uuid/$exec_uuid.jsonl>. Does B<not> create the
file, but the run directory must already exist (call C<run_log_dir> first).

=item $ws->cleanup()

Removes the entire root directory tree via L<File::Path/remove_tree>.

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

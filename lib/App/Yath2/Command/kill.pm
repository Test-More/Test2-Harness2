package App::Yath2::Command::kill;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/sleep time/;

use App::Yath2::Util::IPC qw/discover_daemons unlink_ipc_file/;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

use Object::HashBase qw{
    <args
    <settings
};

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Harness',
    'App::Yath2::Options::IPC',
);

option_group {group => 'kill', category => "Kill Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to kill. Without --workdir / --ipc-file, the running daemon is auto-discovered.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, kill the most recently started one instead of erroring.',
    );

    option all => (
        type        => 'Bool',
        default     => 0,
        description => 'Kill every daemon owned by this user in this project (auto-discovery only).',
    );

    option signal => (
        type          => 'Scalar',
        default       => 'KILL',
        long_examples => [' KILL|TERM|INT|...'],
        description   => 'Signal name (or number) to send. Defaults to KILL for immediate termination.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Hard-kill a running yath daemon" }

sub description {
    return <<"    EOT";
Send SIGKILL (or another signal via --signal) directly to a running
yath daemon's pid. No graceful shutdown. Use `yath stop` when the daemon should
be allowed to finish in-flight work.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $signal   = $settings->kill->signal;

    my @records = $self->_collect_targets;

    my $any_fail = 0;
    for my $info (@records) {
        my $pid  = $info->{pid};
        my $path = $info->{_path};

        unless ($pid) {
            warn "IPC info file '$path' is missing the harness pid\n";
            $any_fail = 1;
            next;
        }

        if (!kill 0 => $pid) {
            unlink_ipc_file($path);
            print "already gone: pid=$pid workdir=" . ($info->{workdir} // '?') . "\n";
            next;
        }

        my $sent = kill $signal, $pid;
        unless ($sent) {
            warn "kill $signal pid=$pid failed: $!\n";
            $any_fail = 1;
            next;
        }

        # Give the kernel a beat; for SIGKILL the pid usually goes
        # within a few ms.
        my $deadline = time + 2;
        while (time < $deadline) {
            last unless kill 0 => $pid;
            sleep 0.05;
        }
        unlink_ipc_file($path) if -e $path && !kill(0 => $pid);

        print "killed (SIG$signal): pid=$pid workdir=" . ($info->{workdir} // '?') . "\n";
    }

    return $any_fail ? 1 : 0;
}

sub _collect_targets {
    my $self = shift;
    my $settings = $self->{+SETTINGS};
    my $kill     = $settings->kill;

    # Group->all is a real method that returns the options hash (always truthy);
    # use option('all') to read the actual --all flag value.
    if ($kill->option('all')) {
        my $list = discover_daemons(
            settings => $settings,
            count    => 'all',
        );
        die "No running yath daemon found.\n" unless @$list;
        return @$list;
    }

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $kill->workdir,
        latest   => $kill->latest,
    );
    return ($info);
}

1;

__END__

=head1 METHODS

=head2 load_plugins / load_resources / load_renderers / accepts_dot_args / args_include_tests

Standard Command framework hooks (see L<App::Yath2::Role::Command>). All return
false: kill is a signal-sender that needs no plugins, resources, renderers, or
test arguments.

=head2 _collect_targets

Resolve the set of daemon IPC info records to signal. Honors C<--all>,
C<--workdir>, and C<--latest> via L<App::Yath2::Util::IPC/discover_daemons>.

=head1 POD IS AUTO-GENERATED

=cut

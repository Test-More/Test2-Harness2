package App::Yath2::Command::stop;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/sleep time/;

use Test2::Harness2::Spawn;
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

option_group {group => 'stop', category => "Stop Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to stop. Without --workdir / --ipc-file, the running daemon is auto-discovered.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, stop the most recently started one instead of erroring.',
    );

    option all => (
        type        => 'Bool',
        default     => 0,
        description => 'Stop every daemon owned by this user in this project (auto-discovery only).',
    );

    option timeout => (
        type        => 'Scalar',
        default     => 30,
        long_examples => [' SECS'],
        description => 'Seconds to wait for the daemon to exit after sending TERM before giving up.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Gracefully stop a running yath daemon" }

sub description {
    return <<"    EOT";
Send a graceful shutdown request to a running yath daemon. Pending
runs are aborted, the daemon exits, and its IPC info file is cleaned
up. Exits 0 once every targeted daemon has terminated.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $timeout  = $settings->stop->timeout;

    my @records = $self->_collect_targets;

    my $any_fail = 0;
    for my $info (@records) {
        my $ok = eval { $self->_stop_one($info, $timeout); 1 };
        unless ($ok) {
            my $err = $@;
            warn "stop pid=$info->{pid} ($info->{_path}): $err";
            $any_fail = 1;
            next;
        }
    }

    return $any_fail ? 1 : 0;
}

sub _collect_targets {
    my $self = shift;
    my $settings = $self->{+SETTINGS};
    my $stop     = $settings->stop;

    # Group->all is a real method that returns the options hash (always truthy);
    # use option('all') to read the actual --all flag value.
    if ($stop->option('all')) {
        my $list = discover_daemons(
            settings => $settings,
            count    => 'all',
        );
        die "No running yath daemon found.\n" unless @$list;
        return @$list;
    }

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $stop->workdir,
        latest   => $stop->latest,
    );
    return ($info);
}

sub _stop_one {
    my ($self, $info, $timeout) = @_;
    my $pid = $info->{pid};
    my $path = $info->{_path};

    die "IPC info file '$path' is missing the harness pid\n" unless $pid;

    if (!kill 0 => $pid) {
        # Stale IPC file: pid is already gone. Clean up and report.
        unlink_ipc_file($path);
        print "already gone: pid=$pid workdir=" . ($info->{workdir} // '?') . "\n";
        return;
    }

    # Prefer in-bus terminate so the harness drains; fall back to a
    # SIGTERM signal if the bus dial fails (e.g. corrupt IPC info).
    my $sent_ok = eval {
        my $spawn = Test2::Harness2::Spawn->new(
            pid                  => $pid,
            ipcm_info            => $info->{ipcm_info},
            workdir              => $info->{workdir},
            terminate_on_destroy => 0,
        );
        $spawn->terminate;
        1;
    };
    unless ($sent_ok) {
        my $err = $@;
        warn "spawn->terminate failed for pid=$pid: $err; falling back to SIGTERM\n";
        kill 'TERM', $pid;
    }

    my $deadline = time + $timeout;
    while (time < $deadline) {
        last unless kill 0 => $pid;
        sleep 0.1;
    }

    if (kill 0 => $pid) {
        die "daemon pid=$pid did not exit within ${timeout}s (use `yath kill` to force).\n";
    }

    # Watchdog cleans the IPC file once the daemon exits, but it may
    # race our scan; unlink defensively after we observe pid gone.
    unlink_ipc_file($path) if -e $path;

    print "stopped: pid=$pid workdir=" . ($info->{workdir} // '?') . "\n";
    return;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

=cut

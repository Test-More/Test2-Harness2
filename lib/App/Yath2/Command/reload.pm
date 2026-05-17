package App::Yath2::Command::reload;
use strict;
use warnings;

our $VERSION = '2.000013';

use Test2::Harness2::Spawn;
use App::Yath2::Util::IPC qw/discover_daemons assert_daemon_alive/;

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

option_group {group => 'reload', category => "Reload Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to reload.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, reload the most recently started.',
    );

    option wait => (
        type        => 'Bool',
        default     => 0,
        description => 'Block until every targeted preload service finishes reloading.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Reload global preloads on a running yath daemon" }

sub description {
    return <<"    EOT";
Ask each global-scope preload service on a running yath daemon to
re-run its reloader. Run-scoped preloads are intentionally skipped.

By default the request is fire-and-forget; pass --wait to block until
each preload returns from its reload.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;

    my $settings = $self->{+SETTINGS};
    my $opts     = $settings->reload;

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $opts->workdir,
        latest   => $opts->latest,
    );
    assert_daemon_alive($info);

    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $info->{pid},
        ipcm_info            => $info->{ipcm_info},
        workdir              => $info->{workdir},
        terminate_on_destroy => 0,
    );

    my $peers = _fetch_preload_peers($spawn);
    unless (@$peers) {
        print "No global preload services configured on this daemon.\n";
        return 0;
    }

    my $any_fail = 0;
    for my $peer (@$peers) {
        my $ok = $opts->wait
            ? _reload_sync($spawn->handle, $peer)
            : _reload_broadcast($spawn, $peer);
        $any_fail = 1 unless $ok;
    }

    return $any_fail ? 1 : 0;
}

sub _fetch_preload_peers {
    my ($spawn) = @_;
    my $list = $spawn->_send_request('list_preloads');
    unless (ref($list) eq 'HASH' && $list->{ok}) {
        my $err = ref($list) eq 'HASH' ? ($list->{error} // 'unknown error') : '(no response)';
        die "list_preloads failed: $err\n";
    }
    return $list->{preloads} // [];
}

sub _reload_sync {
    my ($handle, $peer) = @_;
    my $name = $peer->{name};

    my $envelope;
    my $ok = eval { $envelope = $handle->sync_request($name, {request => 'reload'}); 1 };
    if (!$ok) {
        my $err = $@; chomp $err;
        printf("%s pid=%s ERROR (%s)\n", $name, ($peer->{pid} // '?'), $err);
        return 0;
    }

    # sync_request returns the bus envelope { ipcm_request_id, response };
    # the handler's return value is the inner 'response' hash.
    my $res = (ref($envelope) eq 'HASH' && ref($envelope->{response}) eq 'HASH')
        ? $envelope->{response}
        : (ref($envelope) eq 'HASH' ? $envelope : {});
    my $rok  = ref($res) eq 'HASH' && $res->{ok};
    my $noop = $rok && $res->{noop};
    my $status =
          !$rok ? 'failed'
        : $noop ? 'no-op (no reloader configured)'
        :         'reloaded ok';

    printf("%s pid=%s %s%s\n",
        $name, ($peer->{pid} // '?'),
        $status,
        ($rok ? '' : ' (' . ($res->{error} // '?') . ')'),
    );
    return $rok ? 1 : 0;
}

sub _reload_broadcast {
    my ($spawn, $peer) = @_;
    my $name = $peer->{name};

    my $ok = $spawn->broadcast_message($name, {request => 'reload'});
    if (!$ok) {
        my $err = $@; chomp $err;
        printf("%s pid=%s ERROR (%s)\n", $name, ($peer->{pid} // '?'), $err);
        return 0;
    }
    printf("%s pid=%s reload queued\n", $name, ($peer->{pid} // '?'));
    return 1;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

=cut

package App::Yath2::Command::abort;
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

option_group {group => 'abort', category => "Abort Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to abort runs on.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, abort runs on the most recently started.',
    );

    option run_id => (
        type          => 'Scalar',
        long_examples => [' ID'],
        description   => 'Abort a specific run on the daemon. Defaults to --all.',
    );

    option all => (
        type        => 'Bool',
        default     => 0,
        description => 'Abort every active run on the daemon. Implied when --run-id is not given.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Cancel pending tests on a running yath daemon" }

sub description {
    return <<"    EOT";
Tell a running yath daemon to drop the remaining pending tests in
one specific run (with --run-id ID) or in every active run
(default; --all is explicit). Currently running tests keep running;
the daemon stays up.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;

    my $settings = $self->{+SETTINGS};
    my $opts     = $settings->abort;

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

    my $rid = $opts->run_id;
    my %payload = defined($rid) && length($rid)
        ? (run_id => $rid)
        : (all => 1);

    my $res = $spawn->_send_request('abort_run', \%payload);
    unless (ref($res) eq 'HASH' && $res->{ok}) {
        my $err = ref($res) eq 'HASH' ? ($res->{error} // 'unknown error') : '(no response)';
        if ($err =~ /no run with id/) {
            print STDERR "$err\n";
            return 1;
        }
        die "abort_run failed: $err\n";
    }

    my $aborted = $res->{aborted} // [];
    unless (@$aborted) {
        print "No matching active runs.\n";
        return 0;
    }

    print "aborted: $_\n" for @$aborted;
    return 0;
}

1;

__END__

=head1 METHODS

=head2 load_plugins / load_resources / load_renderers / accepts_dot_args / args_include_tests

Standard Command framework hooks (see L<App::Yath2::Role::Command>). Return
constants describing this command's behavior. All return false: abort is a
short-lived client that only talks to an existing daemon.

=head1 POD IS AUTO-GENERATED

=cut

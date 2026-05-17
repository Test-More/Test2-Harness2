package App::Yath2::Command::status;
use strict;
use warnings;

our $VERSION = '2.000013';

use POSIX qw/strftime/;

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

option_group {group => 'status', category => "Status Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to query. Without --workdir / --ipc-file, auto-discover a single daemon.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, show status of the most recently started one.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Show status of a running yath daemon" }

sub description {
    return <<"    EOT";
Connect to a running yath daemon and print a summary of its state:
service identity, pending/running/completed runs, in-flight jobs, and
the active resource services.
    EOT
}

# Function too long, break it up
sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};

    my $info = discover_daemons(
        settings => $settings,
        workdir  => $settings->status->workdir,
        latest   => $settings->status->latest,
    );

    assert_daemon_alive($info);

    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $info->{pid},
        ipcm_info            => $info->{ipcm_info},
        workdir              => $info->{workdir},
        terminate_on_destroy => 0,
    );

    my $st = $spawn->status;
    die "harness returned no status\n" unless ref($st) eq 'HASH';

    my $svc = $st->{service} // {};
    print "Service:\n";
    print "  pid      : ", ($svc->{pid}     // '?'), "\n";
    print "  name     : ", ($svc->{name}    // '?'), "\n";
    print "  workdir  : ", ($svc->{workdir} // '?'), "\n";
    print "  state    : ", ($svc->{state}   // '?'), "\n";
    print "  started  : ", _fmt_stamp($info->{created_at}), "\n";
    print "  ipc_file : $info->{_path}\n";

    my $queue   = $st->{queue}   // [];
    my $running = $st->{running} // [];
    my $rsrc    = $st->{resources} // [];

    print "\nRuns: ", scalar(@$queue), " queued\n";
    for my $r (@$queue) {
        printf("  run_id=%s  pending=%d  running=%d  done=%d\n",
            $r->{run_id} // '?',
            scalar @{$r->{pending} // []},
            scalar @{$r->{running} // []},
            scalar @{$r->{done}    // []},
        );
    }

    print "\nIn-flight jobs: ", scalar(@$running), "\n";
    for my $j (@$running) {
        printf("  run=%s  job=%s  pid=%s  file=%s\n",
            $j->{run_id} // '?', $j->{job_id} // '?',
            $j->{pid} // '?', $j->{test_file} // '?',
        );
    }

    print "\nResources: ", scalar(@$rsrc), "\n";
    for my $r (@$rsrc) {
        if (ref($r) eq 'HASH') {
            my $name = $r->{resource} // $r->{name} // '?';
            my @keys = grep { $_ ne 'resource' && $_ ne 'name' && $_ ne 'assignments' } sort keys %$r;
            my $detail = join ' ', map {
                my $v = $r->{$_};
                "$_=" . (ref($v) ? ref($v) : (defined $v ? $v : ''));
            } @keys;
            print "  $name" . ($detail ? "  $detail" : '') . "\n";
        }
        else {
            print "  ", (defined $r ? $r : '?'), "\n";
        }
    }

    return 0;
}

sub _fmt_stamp {
    my ($epoch) = @_;
    return '?' unless defined $epoch && $epoch =~ /^\d/;
    return strftime('%Y-%m-%d %H:%M:%S', localtime($epoch));
}

1;

__END__

=head1 POD IS AUTO-GENERATED

=cut

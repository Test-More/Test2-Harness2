package App::Yath2::Command::ps;
use strict;
use warnings;

our $VERSION = '2.000013';

use POSIX qw/strftime/;
use Term::Table();

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

option_group {group => 'ps', category => "PS Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to query (single-daemon mode).',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, pick the most recently started.',
    );

    option all_projects => (
        type        => 'Bool',
        default     => 0,
        description => 'List in-flight jobs across all projects, not just this one.',
    );

    option all_users => (
        type        => 'Bool',
        default     => 0,
        description => 'List in-flight jobs across all users.',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "List in-flight tests on running yath daemons" }

sub description {
    return <<"    EOT";
Connect to every matching yath daemon and print its in-flight jobs:
service pid, run_id, job_id, test file, age.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;

    my $settings = $self->{+SETTINGS};
    my $ps       = $settings->ps;

    my $single = $ps->workdir ? 1 : 0;
    my @daemons;
    if ($ps->workdir) {
        my $info = discover_daemons(
            settings => $settings,
            workdir  => $ps->workdir,
            latest   => $ps->latest,
        );
        push @daemons, $info;
    }
    else {
        my $list = discover_daemons(
            settings => $settings,
            count    => 'all',
            ($ps->all_projects ? (project => undef) : ()),
            ($ps->all_users    ? (user    => undef) : ()),
        );
        unless (@$list) {
            print "No running yath daemons.\n";
            return 0;
        }
        push @daemons, @$list;
    }

    my $now = time;
    my $any = 0;
    for my $info (@daemons) {
        my $ok  = eval { assert_daemon_alive($info); 1 };
        my $err = $@;
        unless ($ok) {
            die $err if $single;
            warn $err;
            next;
        }

        my $spawn = Test2::Harness2::Spawn->new(
            pid                  => $info->{pid},
            ipcm_info            => $info->{ipcm_info},
            workdir              => $info->{workdir},
            terminate_on_destroy => 0,
        );

        my $st;
        my $sok  = eval { $st = $spawn->status; 1 };
        my $serr = $@;
        unless ($sok) {
            die $serr if $single;
            warn "ps: status for pid=$info->{pid} failed: $serr";
            next;
        }

        my $svc     = $st->{service} // {};
        my $running = $st->{running} // [];

        printf("Daemon: pid=%s workdir=%s (state=%s) — %d in-flight job(s)\n",
            ($svc->{pid}     // '?'),
            ($svc->{workdir} // '?'),
            ($svc->{state}   // '?'),
            scalar @$running,
        );

        if (@$running) {
            my @rows;
            for my $j (@$running) {
                my $age = defined $j->{started}
                    ? sprintf("%.1fs", $now - $j->{started})
                    : '?';
                push @rows => [
                    ($j->{pid}       // '?'),
                    ($j->{run_id}    // '?'),
                    ($j->{job_id}    // '?'),
                    ($j->{test_file} // '?'),
                    $age,
                ];
            }
            my $table = Term::Table->new(
                collapse => 1,
                header   => [qw/PID RUN_ID JOB_ID TEST_FILE AGE/],
                rows     => \@rows,
            );
            print "  $_\n" for $table->render;
        }

        my $services = $st->{services} // [];
        if (@$services) {
            my @rows;
            for my $s (@$services) {
                push @rows => [
                    ($s->{pid}           // '?'),
                    ($s->{name}          // '?'),
                    ($s->{service_class} // '?'),
                    ($s->{scope}         // '?'),
                    ($s->{via_preload}   ? 'yes' : 'no'),
                ];
            }
            my $table = Term::Table->new(
                collapse => 1,
                header   => [qw/PID NAME CLASS SCOPE VIA_PRELOAD/],
                rows     => \@rows,
            );
            print "  Services:\n";
            print "    $_\n" for $table->render;
        }
        print "\n";

        $any = 1;
    }

    return $any ? 0 : 1;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

=cut

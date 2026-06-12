package App::Yath2::Command::list;
use strict;
use warnings;

our $VERSION = '2.000013';

use POSIX qw/strftime/;
use Term::Table();

use App::Yath2::Util::IPC qw/discover_daemons/;

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

option_group {group => 'list', category => "List Options"} => sub {
    option all_projects => (
        type        => 'Bool',
        default     => 0,
        description => 'List daemons across all projects, not just this one.',
    );

    option all_users => (
        type        => 'Bool',
        default     => 0,
        description => 'List daemons across all users (only meaningful when IPC files are world-readable).',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "List running yath daemons" }

sub description {
    return <<"    EOT";
Scan the IPC directories for live `yath start` daemons owned by this
user, in this project. Use --all-projects or --all-users to widen the
scope.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;
    STDERR->autoflush(1);

    my $settings = $self->{+SETTINGS};
    my $list_opts = $settings->list;

    my $all = discover_daemons(
        settings => $settings,
        count    => 'all',
        ($list_opts->all_projects ? (project => undef) : ()),
        ($list_opts->all_users    ? (user    => undef) : ()),
    );

    my @rows;
    for my $rec (@$all) {
        push @rows => [
            $rec->{pid}     // '?',
            $rec->{project} // '?',
            $rec->{user}    // '?',
            _fmt_stamp($rec->{created_at}),
            $rec->{workdir} // '?',
            $rec->{_path}   // '?',
        ];
    }

    if (!@rows) {
        print "No running yath daemons.\n";
        return 0;
    }

    my $table = Term::Table->new(
        header => [qw/PID PROJECT USER STARTED WORKDIR IPC_FILE/],
        rows   => \@rows,
    );

    print "$_\n" for $table->render;
    return 0;
}

sub _fmt_stamp {
    my ($epoch) = @_;
    return '?' unless defined $epoch && $epoch =~ /^\d/;
    return strftime('%Y-%m-%d %H:%M:%S', localtime($epoch));
}

1;

__END__

=head1 METHODS

=head2 load_plugins / load_resources / load_renderers / accepts_dot_args / args_include_tests

Standard Command framework hooks (see L<App::Yath2::Role::Command>). All return
false: list only scans IPC info files, no harness machinery is needed.

=head2 _fmt_stamp

Format an epoch timestamp as C<YYYY-MM-DD HH:MM:SS> in local time, or C<?>
when the value is missing/invalid.

=head1 POD IS AUTO-GENERATED

=cut

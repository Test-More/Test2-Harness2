package App::Yath2::Command::which;
use strict;
use warnings;

our $VERSION = '2.000013';

use IPC::Manager::Serializer::JSON();

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

option_group {group => 'which', category => "Which Options"} => sub {
    option workdir => (
        type           => 'Scalar',
        long_examples  => [' DIR'],
        short_examples => [' DIR'],
        description    => 'Workdir of the daemon to locate. Without --workdir / --ipc-file, the running daemon is auto-discovered.',
    );

    option latest => (
        type        => 'Bool',
        default     => 0,
        description => 'When multiple daemons match, return the most recently started.',
    );

    option all => (
        type        => 'Bool',
        default     => 0,
        description => 'Return every running daemon owned by this user in this project.',
    );

    option json => (
        type        => 'Bool',
        default     => 0,
        description => 'Emit the IPC info record as JSON (one record per line under --all).',
    );
};

sub load_plugins   { 0 }
sub load_resources { 0 }
sub load_renderers { 0 }

sub accepts_dot_args   { 0 }
sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary { "Locate a running yath daemon" }

sub description {
    return <<"    EOT";
Look up which yath daemon `yath run` (and friends) would target right now
and print its IPC info record: pid, workdir, IPC file path, start
timestamp. Use --all to list every match.
    EOT
}

sub run {
    my $self = shift;

    local $| = 1;

    my $settings = $self->{+SETTINGS};
    my $which    = $settings->which;

    my @records = $self->_collect($which);

    return 1 unless @records;

    if ($which->json) {
        for my $rec (@records) {
            print IPC::Manager::Serializer::JSON->serialize($self->_jsonable($rec)) . "\n";
        }
        return 0;
    }

    for my $rec (@records) {
        print "Found persistent runner:\n";
        for my $field (qw/pid project user stamp workdir hostname _path uuid ipcm_info/) {
            next unless defined $rec->{$field};
            my $v = $rec->{$field};
            $v = ref($v) ? IPC::Manager::Serializer::JSON->serialize($v) : $v;
            printf("  %-9s: %s\n", $field, $v);
        }
        print "\n";
    }

    return 0;
}

sub _collect {
    my ($self, $which) = @_;
    my $settings = $self->{+SETTINGS};

    # NOTE: use ->option(NAME) for `all` and `option` because
    # Getopt::Yath::Settings::Group has built-in methods with those
    # names that shadow the AUTOLOAD-generated accessors.
    if ($which->option('all')) {
        my $list = discover_daemons(settings => $settings, count => 'all');
        unless (@$list) {
            print STDERR "No persistent harness found for the current project.\n";
            return;
        }
        return @$list;
    }

    my $info = eval {
        discover_daemons(
            settings => $settings,
            workdir  => $which->workdir,
            latest   => $which->latest,
        );
    };
    if (my $err = $@) {
        # Carp::croak always appends "at FILE line N." after the
        # caller's message, even when the message ends in \n. Strip
        # the location so users see the friendly croak text only.
        $err =~ s/\s*at\s+\S+\s+line\s+\d+\.\s*\z//s;
        chomp $err;
        print STDERR "$err\n";
        return;
    }
    return ($info);
}

sub _jsonable {
    my ($self, $rec) = @_;
    # Shallow copy and drop the internal _path key from the JSON
    # output so the JSON record matches the IPC info file on disk.
    return { map { $_ => $rec->{$_} } grep { !/^_/ } keys %$rec };
}

1;

__END__

=head1 METHODS

=head2 load_plugins / load_resources / load_renderers / accepts_dot_args / args_include_tests

Standard Command framework hooks (see L<App::Yath2::Role::Command>). All return
false: which only reads IPC info files and prints them.

=head2 _collect

Return the IPC info records matching the user's selectors (C<--all>,
C<--workdir>, C<--latest>), printing friendly diagnostics to STDERR on
not-found and returning the empty list.

=head2 _jsonable

Shallow-copy an IPC info record and drop internal C<_>-prefixed keys so the
JSON output matches the on-disk IPC info file.

=head1 POD IS AUTO-GENERATED

=cut

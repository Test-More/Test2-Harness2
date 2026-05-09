package App::Yath2::DB::Iterator;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Object::HashBase qw{
    <db
    <uuid
    +_archive_id
    +_stack
    +_seen_starts
    +_closed_starts
    +_count
};

use Role::Tiny::With;
with 'App::Yath2::Role::EventIterator';

# Depth-first walker over the events.jsonl streams of a single DB
# archive. Construction binds the iterator to a single (db, uuid)
# pair; the archive_id is resolved eagerly so a bad uuid (or an
# archive_version mismatch) croaks at construction time rather than on
# first ->next.
#
# State (stack, seen_starts, closed_starts) lives on the iterator
# instance, so multiple iterators against the same DB do not share
# walker state. The archive is sealed on disk; ->next never blocks and
# there is no $timeout argument.

sub init {
    my $self = shift;

    croak "'db' is required (must be an App::Yath2::DB instance)"
        unless defined $self->{+DB};
    croak "'db' must be an App::Yath2::DB instance"
        unless eval { $self->{+DB}->isa('App::Yath2::DB') };
    croak "'uuid' is required" unless defined $self->{+UUID};

    # Eager resolution: bad uuid / archive_version mismatch must surface
    # at construction time, not on first ->next.
    $self->{+_ARCHIVE_ID} = $self->{+DB}->_resolve_archive_id($self->{+UUID});

    return;
}

# Lazy stack seed: open the harness root events.jsonl. The walker
# self-expands whenever it sees a harness_collector_start facet.
sub _seed_stack {
    my $self = shift;
    return [
        $self->_open_walk(base => 'services/harness', service => 'harness'),
    ];
}

sub next {
    my $self = shift;

    my $stack = $self->{+_STACK} //= $self->_seed_stack;

    while (1) {
        last unless @$stack;

        my $got;
        my $owner;
        for (my $i = $#$stack; $i >= 0; $i--) {
            my $entry = $stack->[$i];
            if ($entry->{idx} < scalar @{$entry->{records}}) {
                $got = $entry->{records}[$entry->{idx}++];
                $owner = $entry;
                last;
            }
        }

        if (defined $got) {
            if (my $start = $self->_facet($got, 'harness_collector_start')) {
                my $cpid = $start->{collector_pid};
                $self->{+_SEEN_STARTS}{$cpid} = $start if defined $cpid;
                my $child_base = $self->_base_for_collector_start($start);
                if (defined $child_base) {
                    my %args = (base => $child_base, collector_pid => $cpid);
                    my $type = $start->{type};
                    if ($type eq 'Job') {
                        $args{run_id}  = $start->{run_id};
                        $args{job_id}  = $start->{id};
                        $args{job_try} = $start->{job_try} // 0;
                    }
                    elsif ($type eq 'Run') {
                        $args{run_id} = $start->{id};
                    }
                    elsif ($type eq 'Service') {
                        $args{service} = $start->{service_name} // $start->{id};
                        $args{run_id}  = $start->{run_id} if defined $start->{run_id};
                    }
                    push @$stack => $self->_open_walk(%args);
                }
                return $self->_inject_identifiers($got, $owner->{ident});
            }

            if (my $end = $self->_facet($got, 'harness_collector_end')) {
                my $cpid = $end->{collector_pid};
                $self->{+_CLOSED_STARTS}{$cpid} = 1 if defined $cpid;
                return $self->_inject_identifiers($got, $owner->{ident});
            }

            return $self->_inject_identifiers($got, $owner->{ident});
        }

        while (@$stack && $stack->[-1]{idx} >= scalar @{$stack->[-1]{records}}) {
            pop @$stack;
        }
        last if !@$stack;
    }

    return undef;
}

sub EOE {
    my $self = shift;
    my $stack = $self->{+_STACK} //= $self->_seed_stack;

    while (@$stack) {
        return 0 if $stack->[-1]{idx} < scalar @{$stack->[-1]{records}};
        pop @$stack;
    }
    return 1;
}

sub reset {
    my $self = shift;
    delete $self->{+_STACK};
    delete $self->{+_SEEN_STARTS};
    delete $self->{+_CLOSED_STARTS};
    return;
}

# Cached after the first call. Result is the SUM(row_count) over every
# events artifact in the archive (which is exactly the set the depth-
# first walker visits).
sub count {
    my $self = shift;
    return $self->{+_COUNT}
        //= $self->{+DB}->backend->artifact_event_count_for_archive($self->{+_ARCHIVE_ID});
}

# -----------------------------------------------------------------------
# Private helpers (lifted verbatim from App::Yath2::DB's walker)
# -----------------------------------------------------------------------

# Open a single walk frame: load the events.jsonl records at $base and
# remember which scoped identifiers should be back-injected onto every
# event yielded from this frame.
sub _open_walk {
    my ($self, %args) = @_;
    my $base = $args{base};
    my $records = $self->{+DB}->artifact_iter_records($self->{+UUID}, $base, 'events.jsonl') || [];
    return {
        records => $records,
        idx     => 0,
        base    => $base,
        ident   => {
            (defined $args{run_id}  ? (run_id  => $args{run_id})  : ()),
            (defined $args{job_id}  ? (job_id  => $args{job_id})  : ()),
            (defined $args{job_try} ? (job_try => $args{job_try}) : ()),
            (defined $args{service} ? (service_name => $args{service}) : ()),
        },
        collector_pid => $args{collector_pid},
    };
}

sub _facet {
    my ($self, $event, $name) = @_;
    return undef unless ref($event) eq 'HASH';
    my $fd = $event->{facet_data};
    return undef unless ref($fd) eq 'HASH';
    return $fd->{$name};
}

sub _base_for_collector_start {
    my ($self, $content) = @_;
    return undef unless ref($content) eq 'HASH';
    my $type = $content->{type};
    return undef unless defined $type;

    if ($type eq 'Job') {
        my $rid = $content->{run_id};
        my $jid = $content->{id};
        my $try = $content->{job_try} // 0;
        return undef unless defined $rid && defined $jid;
        return "runs/$rid/jobs/$jid/$try";
    }
    if ($type eq 'Run') {
        my $rid = $content->{id};
        return undef unless defined $rid;
        return "runs/$rid";
    }
    if ($type eq 'Service') {
        my $name = $content->{service_name} // $content->{id};
        return undef unless defined $name && length $name;
        my $rid = $content->{run_id};
        return defined $rid ? "runs/$rid/services/$name" : "services/$name";
    }
    return undef;
}

sub _inject_identifiers {
    my ($self, $event, $ident) = @_;
    return $event unless ref($event) eq 'HASH';

    my $fd = $event->{facet_data} // do { $event->{facet_data} = {}; $event->{facet_data} };
    my $h = $fd->{harness} // do { $fd->{harness} = {}; $fd->{harness} };

    for my $k (qw/run_id job_id job_try service_name/) {
        next unless exists $ident->{$k};
        $h->{$k} //= $ident->{$k};
    }
    return $event;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::Iterator - Depth-first event walker over a single DB archive.

=head1 DESCRIPTION

Iterator over the events.jsonl streams of a single archive in an
L<App::Yath2::DB>. Constructed via C<< $db->iterator($uuid) >>.

The iterator opens the harness root C<services/harness/events.jsonl>
and walks every collector subtree the harness root announces (Run,
Service, Job). Records are returned in depth-first order, with scoped
identifiers (C<run_id>, C<job_id>, C<job_try>, C<service_name>)
back-injected onto each event's harness facet.

The archive is sealed on disk; C<next> never blocks and there is no
C<$timeout> argument.

This class consumes L<App::Yath2::Role::EventIterator>.

=head1 SYNOPSIS

    use App::Yath2::DB;

    my $db   = App::Yath2::DB->new(file => '/tmp/run.yath');
    my ($u)  = $db->archives;
    my $iter = $db->iterator($u);

    while (my $event = $iter->next) {
        ...
    }

    # Or:
    my @all = $db->iterator($u)->all;
    my $n   = $db->iterator($u)->count;
    my $e0  = $db->iterator($u)->first;

=head1 ATTRIBUTES

=over 4

=item $db = $iter->db

The underlying L<App::Yath2::DB>.

=item $uuid = $iter->uuid

The archive uuid this iterator is bound to.

=back

=head1 METHODS

=over 4

=item $event = $iter->next

Return the next decoded event, or undef when the walk has drained.

=item $bool = $iter->EOE

True once the walk's stack is empty.

=item $iter->reset

Rewind walker state; the next C<next> call re-seeds from the harness
root.

=item $n = $iter->count

Total number of events this iterator will yield. Computed via a single
C<SUM(row_count)> query on the archive's events artifacts; cached on
the iterator after the first call.

=item @events = $iter->all

(provided by L<App::Yath2::Role::EventIterator>) Drain to a list.

=item $event = $iter->first

(provided by L<App::Yath2::Role::EventIterator>) Reset and return the
first event.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

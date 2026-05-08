package Test2::Harness2::Event;
use strict;
use warnings;

our $VERSION = '2.000012';

use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <facet_data
    <compressed_form
    +json
};

sub init {
    my $self = shift;

    $self->{+FACET_DATA} //= {};
}

sub as_json { $_[0]->{+JSON} //= encode_json($_[0]) }

# Drop the cached on-wire compressed bytes (and the cached JSON
# encoding that pairs with them). Auditors and other consumers that
# mutate the event must call this so a downstream zstd-aware logger
# does not write stale compressed bytes that no longer match the
# (mutated) event body.
sub clear_compressed_form {
    my $self = shift;
    delete $self->{+COMPRESSED_FORM};
    delete $self->{+JSON};
    return;
}

# Shortcut accessors that read from canonical homes inside facet_data.
# Identifier and timing fields no longer live on the event hash
# directly -- they live in the facets that own them. These accessors
# paper over the relocation for callers that still want
# `$event->stamp` / `$event->pid` / etc.
#
# event_id is intentionally a stub returning undef: the field is no
# longer generated anywhere on the live-write path. Callers that needed
# it must use a derived path-aware key the Log iterator injects on read.

sub event_id { undef }

sub stamp   { my $f = $_[0]->{+FACET_DATA}; $f && $f->{trace}   ? $f->{trace}->{stamp}   : undef }
sub pid     { my $f = $_[0]->{+FACET_DATA}; $f && $f->{trace}   ? $f->{trace}->{pid}     : undef }
sub tid     { my $f = $_[0]->{+FACET_DATA}; $f && $f->{trace}   ? $f->{trace}->{tid}     : undef }
sub run_id  { my $f = $_[0]->{+FACET_DATA}; $f && $f->{harness} ? $f->{harness}->{run_id}  : undef }
sub job_id  { my $f = $_[0]->{+FACET_DATA}; $f && $f->{harness} ? $f->{harness}->{job_id}  : undef }
sub job_try { my $f = $_[0]->{+FACET_DATA}; $f && $f->{harness} ? $f->{harness}->{job_try} : undef }

sub TO_JSON {
    my $out = {%{$_[0]}};

    delete $out->{+JSON};
    delete $out->{+COMPRESSED_FORM};

    if (my $fd = $out->{+FACET_DATA}) {
        my %copy;
        for my $key (keys %$fd) {
            my $val = $fd->{$key};
            # Strip empty facets ({} or []) at serialization time.
            if (ref($val) eq 'HASH') {
                next unless keys %$val;
            }
            elsif (ref($val) eq 'ARRAY') {
                next unless @$val;
            }
            $copy{$key} = $val;
        }
        $out->{+FACET_DATA} = \%copy;
    }

    return $out;
}

1;

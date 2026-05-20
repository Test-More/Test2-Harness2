package Test2::Harness2::Row;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Object::HashBase qw{
    +_handle
};

sub TABLE        { croak "subclass must define TABLE" }
sub PRIMARY_KEY  { croak "subclass must define PRIMARY_KEY" }
sub COLUMNS      { croak "subclass must define COLUMNS" }
sub JSON_COLUMNS { () }

sub save {
    my $self = shift;

    my $handle = $self->{+_HANDLE} or croak "row not attached to a handle";
    my $dbh    = $handle->dbh      or croak "handle has no dbh";

    my $table = $self->TABLE;
    my $pk    = $self->PRIMARY_KEY;
    my $pkv   = $self->{$pk};
    croak "row has no primary key value" unless defined $pkv;

    my @cols  = grep { $_ ne $pk } $self->COLUMNS;
    my @binds = map { $self->{$_} } @cols;
    my $sql   = sprintf(
        "UPDATE %s SET %s WHERE %s = ?",
        $table,
        join(', ', map { "$_ = ?" } @cols),
        $pk,
    );

    $dbh->do($sql, undef, @binds, $pkv);
    return $self;
}

sub refresh {
    my $self = shift;

    my $handle = $self->{+_HANDLE} or croak "row not attached to a handle";
    my $dbh    = $handle->dbh      or croak "handle has no dbh";

    my $table = $self->TABLE;
    my $pk    = $self->PRIMARY_KEY;
    my $pkv   = $self->{$pk};
    croak "row has no primary key value" unless defined $pkv;

    my $row = $dbh->selectrow_hashref("SELECT * FROM $table WHERE $pk = ?", undef, $pkv)
        or croak "row $table.$pk=$pkv no longer exists";

    for my $col ($self->COLUMNS) {
        $self->{$col} = $row->{$col};
    }
    return $self;
}

sub TO_JSON {
    my $self = shift;
    my %out;
    for my $col ($self->COLUMNS) {
        $out{$col} = $self->{$col};
    }
    return \%out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Row - Base class for per-table row objects.

=head1 DESCRIPTION

Every database table backs a small subclass of this base. Subclasses
declare their attributes via L<Object::HashBase>, identify their
table via L</TABLE>, identify their primary-key column via
L</PRIMARY_KEY>, and list their full column set via L</COLUMNS>. The
base class then provides the two methods every row needs: L</save>
and L</refresh>.

Row objects are constructed via the handle's L<Test2::Harness2/insert>
or L<Test2::Harness2/fetch> helpers, which inject themselves as the
row's `_handle` attribute. Callers normally do not construct rows
directly.

=head1 CLASS METHODS

=over 4

=item $name = $class->TABLE

Return the SQL table name this row class targets. Subclasses must
override.

=item $name = $class->PRIMARY_KEY

Return the primary-key column name (e.g. C<'user_id'>). Subclasses
must override.

=item @cols = $class->COLUMNS

Return the full ordered list of column names. Subclasses must
override.

=item @cols = $class->JSON_COLUMNS

Return the subset of L</COLUMNS> whose contents are JSON-encoded
strings. Default: empty list. Callers that want decoded Perl data
structures should call L<Test2::Harness2::Util::JSON/decode_json>
on these columns themselves; the row class does not auto-decode.

=back

=head1 PUBLIC METHODS

=over 4

=item $row->save

Write the row's current column values back to the database via a
single C<UPDATE ... WHERE primary_key = ?> statement. Returns the
row itself.

=item $row->refresh

Re-fetch the row by primary key and overwrite this row's column
values with what was just read. Returns the row itself. Croaks if
the row no longer exists.

=item $hash = $row->TO_JSON

Hashref form of the row's column values, used by
L<Cpanel::JSON::XS>'s C<convert_blessed>. The handle reference is
not included.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

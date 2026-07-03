package App::Yath2::DB::ORM;
use strict;
use warnings;

our $VERSION = '2.000000';

# This module pulls in DBIx::QuickORM at compile time, so it must NEVER be loaded
# from the always-loaded command path (spec R11). It is only ever `require`d
# lazily by App::Yath2::DB::Connect (which has already verified DBIx::QuickORM is
# installed) inside a DB-touching process (the logger / db commands).
use DBIx::QuickORM
    rename => {connect => 'qorm_connect'},
    only   => [qw/orm autofill autotype autorow db dialect connect db_name/];

use Carp qw/croak/;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::ORM - Lazily-loaded QuickORM connection builder (the part that
imports L<DBIx::QuickORM>).

=head1 DESCRIPTION

Builds a B<fresh> L<DBIx::QuickORM> ORM with the C<autofill> block defined here --
the single definition (JSON/UUID/DateTime autotypes + the dumb autorow) -- attaches
a db, and returns the live connection. A fresh ORM per call is required because a
C<DBIx::QuickORM::ORM>'s C<db> is write-once, so a shared ORM singleton could never
be re-attached (ticket #93 collapsed the old duplicated definition in
L<App::Yath2::Schema> onto this one; that module is now a thin stable-name
delegator to this builder).

This is split out of L<App::Yath2::DB::Connect> so the C<use DBIx::QuickORM> here
is only paid when a DB process actually loads it (R11) -- C<Connect> verifies the
module is installed and then C<require>s this one.

=head1 FUNCTIONS

=over 4

=item $con = App::Yath2::DB::ORM::connection($name, $dialect, $db_name, $connect_cb)

Build the ORM (named C<$name>, dialect C<$dialect>, autofill from the live DB) and
return the connection. C<$connect_cb> must return a fresh L<DBI> handle each call.

=back

=cut

sub connection {
    my ($name, $dialect, $db_name, $connect_cb) = @_;

    croak "name is required"       unless defined $name;
    croak "dialect is required"    unless defined $dialect;
    croak "db_name is required"    unless defined $db_name;
    croak "connect_cb is required" unless ref($connect_cb) eq 'CODE';

    my $orm = orm($name => sub {
        autofill(sub {
            autotype 'JSON';
            autotype 'UUID';
            autotype 'DateTime';
            autorow 'App::Yath2::Schema::Row';
        });
    });

    $orm->db(db(sub {
        db_name $db_name;
        dialect $dialect;
        qorm_connect($connect_cb);
    }));

    return $orm->connection;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

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

See F<http://dev.perl.org/licenses/>

=cut

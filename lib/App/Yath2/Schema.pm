package App::Yath2::Schema;
use v5.38;

our $VERSION = '2.000000';

# DB layer rewrite (#46 / chunk DB-2). All DB code lives under App::Yath2; the
# backend Test2::Harness2 layer accesses no DB in either direction (spec §0.1/§2).
# This is the live ORM: a DBIx::QuickORM `orm` with `autofill` (reflect-from-DB).
# The schema is NEVER defined in Perl -- the per-flavor DDL under share/schema/ is
# the source of truth, and autofill introspects whatever that DDL produced.
use DBIx::QuickORM;

orm yath => sub {
    # No db here. A db is attached with a connect callback at runtime (see
    # SYNOPSIS) so no credentials live in this file. The schema is introspected
    # from the live database by autofill, which runs lazily when the connection
    # is first built.
    autofill sub {
        autotype 'JSON';                                # JSONB parameters/fields columns
        autotype 'UUID';                                # native uuid PKs/FKs <-> canonical string
        autotype 'DateTime';                            # timestamptz columns <-> DateTime
        autorow 'App::Yath2::Schema::Row';              # dumb autorow under App::Yath2::Schema::Row::
    };
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Schema - The yath database schema, as a DBIx::QuickORM ORM.

=head1 DESCRIPTION

Defines the App::Yath2 database's L<DBIx::QuickORM> ORM, named C<yath>. The ORM
carries no database and no credentials: the schema is built by C<autofill>,
which introspects the live database the first time a connection is made. JSON
(JSONB C<parameters>/C<fields>), UUID, and DateTime (C<timestamptz>) columns are
inflated/deflated automatically, and a row class is generated per table under
C<App::Yath2::Schema::Row::> (a hand-written
C<App::Yath2::Schema::Row::E<lt>TableE<gt>> is loaded if one exists).

The tables themselves are created from the per-flavor DDL shipped under
C<share/schema/> (the source of truth -- there is no Perl schema definition and
no codegen); C<autofill> only reads what that DDL produced, it never creates
tables. UUID values the DB layer inserts are generated in Perl with
L<App::Yath2::Util::UUID> (lowercase v7); the UUID type here only converts
stored values to and from their canonical form.

Row objects are deliberately B<dumb> (DCI / modules-as-actions, spec §2b): no
algorithms live in row classes. Complex logic (import, sync, queries) lives in
dedicated modules/controllers acting on rows.

The DB layer is B<optional> (spec R11): nothing always-loaded C<use>s a DB
module at compile time. C<use>ing this module pulls in L<DBIx::QuickORM>, so it
is only loaded from DB-touching entry points (the logger, the C<db>/C<server>
commands, sync/import), each of which C<require>s its modules lazily with an
actionable error when absent.

Because the ORM has no database, attach one with a C<connect> callback before
asking for a connection. The callback must return a fresh L<DBI> handle each
time it is called.

=head1 SYNOPSIS

C<use>ing this module installs a C<qorm()> accessor into the caller (the default
L<DBIx::QuickORM> export name); C<< qorm(orm => 'yath') >> fetches the ORM.
Attach a database with a C<connect> callback, then ask for the connection:

    use DBIx::QuickORM only => [qw/db dialect connect db_name/];
    use App::Yath2::Schema;

    my $orm = qorm(orm => 'yath');

    $orm->db(db(sub {
        dialect 'PostgreSQL';                   # the dialect is still required
        db_name $db_name;                       # database/catalog autofill reads
        connect(sub { $fresh_dbh });            # any sub returning a NEW DBI handle
    }));

    my $con = $orm->connection;                 # autofill introspects here
    my $run = $con->handle('runs')->insert({ run_uuid => $uuid, ... });

=head1 SEE ALSO

=over 4

=item L<App::Yath2::DB::Flavor>

The per-dialect flavor registry (dialect name, DDL path, live-handle detection,
post-connect PRAGMAs).

=item L<App::Yath2::Util::UUID>

Central lowercase C<gen_uuid()> and the v7-preserving C<derive_uuid()>.

=back

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

package App::Yath2::Schema;
use v5.38;

our $VERSION = '2.000000';

# DB layer rewrite (TODO-46 / chunk DB-2). All DB code lives under App::Yath2; the
# backend Test2::Harness2 layer accesses no DB in either direction (spec §0.1/§2).
#
# This is a thin stable-name delegator (ticket TODO-93). The live ORM builder -- the
# single `autofill` definition (JSON/UUID/DateTime autotypes + the dumb autorow)
# -- lives in L<App::Yath2::DB::ORM>, which every connection is built through
# (a DBIx::QuickORM ORM's `db` is write-once, so a shared singleton could never be
# re-attached; Connect.pm builds a FRESH ORM per connection). Loading this module
# pulls in that builder so the historical `require App::Yath2::Schema` call sites
# keep resolving; the schema is never defined in Perl (the per-flavor DDL under
# share/schema/ is the source of truth, introspected by autofill at connect time).
require App::Yath2::DB::ORM;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Schema - Stable-name delegator to the yath QuickORM connection builder.

=head1 DESCRIPTION

Historically this module registered the App::Yath2 database's L<DBIx::QuickORM>
ORM (named C<yath>). That singleton was never fetched -- every live connection is
built by L<App::Yath2::DB::Connect> through L<App::Yath2::DB::ORM>, which builds a
B<fresh> ORM per connection (a C<DBIx::QuickORM::ORM>'s C<db> is write-once, so a
shared singleton cannot be re-attached). Ticket TODO-93 collapsed the duplicated
C<autofill> block onto that one builder and reduced this module to a thin
delegator that C<require>s L<App::Yath2::DB::ORM>, retained as a stable public
name for the DB-touching entry points (the logger, the C<db> commands,
sync/import) that C<require App::Yath2::Schema>.

The schema itself is created from the per-flavor DDL shipped under
C<share/schema/> (the source of truth -- there is no Perl schema definition and
no codegen); C<autofill> only reads what that DDL produced. JSON (JSONB
C<parameters>/C<fields>), UUID, and DateTime (C<timestamptz>) columns are
inflated/deflated automatically, and a dumb row class is generated per table
under C<App::Yath2::Schema::Row::>. UUID values the DB layer inserts are
generated in Perl with L<App::Yath2::Util::UUID> (lowercase v7).

The DB layer is B<optional> (spec R11): nothing always-loaded C<use>s a DB module
at compile time. This module (and the builder it pulls in) is loaded only from
the DB-touching entry points, each of which C<require>s its modules lazily with an
actionable error when absent.

=head1 SEE ALSO

=over 4

=item L<App::Yath2::DB::ORM>

The actual QuickORM connection builder (the single C<autofill> definition) this
module delegates to.

=item L<App::Yath2::DB::Flavor>

The per-dialect flavor registry (dialect name, DDL path, live-handle detection,
post-connect PRAGMAs).

=item L<App::Yath2::Util::UUID>

Central lowercase C<gen_uuid()> and the v7-preserving C<derive_uuid()>.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

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

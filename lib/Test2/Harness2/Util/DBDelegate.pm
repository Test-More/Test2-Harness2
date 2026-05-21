package Test2::Harness2::Util::DBDelegate;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Test2::Harness2::Util qw/table_to_db_class/;

my %SKIP_DELEGATE = map { $_ => 1 } qw(
    import unimport
    BEGIN END INIT CHECK DESTROY AUTOLOAD UNITCHECK CLONE CLONE_SKIP
    new init
    can isa DOES VERSION
    attr_list add_pre_init add_post_init
    TABLE PRIMARY_KEY COLUMNS JSON_COLUMNS
);

sub import {
    my ($class, $table) = @_;
    my $into = caller;

    croak "Usage: use Test2::Harness2::Util::DBDelegate \$table"
        unless defined $table && length $table;

    my $db_class = table_to_db_class($table);

    unless ($db_class->can('TABLE')) {
        (my $file = $db_class) =~ s{::}{/}g;
        require "$file.pm";
    }

    croak "DB class '$db_class' does not have a TABLE method"
        unless $db_class->can('TABLE');

    my $expected_table = $db_class->TABLE;
    croak "DB class '$db_class' has TABLE='$expected_table', not '$table'"
        unless $expected_table eq $table;

    my @columns   = $db_class->COLUMNS;
    my %is_column = map { $_ => 1 } @columns;

    no strict 'refs';
    no warnings 'redefine';

    *{"${into}::ROW"}      = sub { 'row' };
    *{"${into}::TABLE"}    = sub { $table };
    *{"${into}::DB_CLASS"} = sub { $db_class };
    *{"${into}::row"}      = sub { $_[0]->{row} };

    for my $col (@columns) {
        my $name = $col;
        unless (defined &{"${into}::${name}"}) {
            *{"${into}::${name}"} = sub { $_[0]->{row}->{$name} };
        }
        my $setter = "set_$name";
        unless (defined &{"${into}::${setter}"}) {
            *{"${into}::${setter}"} = sub { $_[0]->{row}->{$name} = $_[1] };
        }
    }

    for my $name (sort keys %{"${db_class}::"}) {
        next if $SKIP_DELEGATE{$name};
        next if $name =~ /^_/;                          # private
        next if $name =~ /^[A-Z][A-Z0-9_]*$/;           # constant
        next if $is_column{$name};                      # column reader (installed)
        next if $name =~ /^set_(.+)$/ && $is_column{$1};# column setter (installed)
        next unless defined &{"${db_class}::${name}"};
        next if defined &{"${into}::${name}"};

        my $method = $name;
        *{"${into}::${name}"} = sub { shift->{row}->$method(@_) };
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::DBDelegate - Install row delegation on a logic
class so its column accessors forward to the underlying DB row.

=head1 SYNOPSIS

    package Test2::Harness2::Runner::Scheduler;
    use strict;
    use warnings;

    use Object::HashBase qw{
        <some_logic_attr
    };

    # Installs ROW constant + row() accessor + per-column delegates
    # reading from $self->{row}, where $self->{row} isa
    # Test2::Harness2::DB::Scheduler.
    use Test2::Harness2::Util::DBDelegate 'schedulers';

    sub init {
        my $self = shift;
        croak "row is required" unless $self->{+ROW};
    }

    sub dispatch_jobs {
        my $self = shift;

        # Read columns via direct-hash delegate ($self->{row}->{col}):
        my $runner_id = $self->runner_id;

        # Write columns via direct-hash setter:
        $self->set_class('My::NewClass');

        # Or apply several changes and persist in one shot:
        $self->save({class => 'My::Other', spec => '{...}'});
    }

=head1 DESCRIPTION

Logic classes in the Test2::Harness2 namespace pair with a "dumb"
row class under C<Test2::Harness2::DB::*>. The dumb row holds column
data and provides L<Test2::Harness2::Role::Row>'s save / refresh
plumbing; the logic class wraps a row and implements behavior. This
helper installs the boilerplate that lets the logic class read row
columns without writing out per-column delegate stubs.

The helper does B<not> touch L<Object::HashBase>. The C<row> slot is
an ordinary hash key; the logic class's HashBase declaration does not
need to mention it (it is not an "attribute" in HashBase's sense, it
is an injected delegate slot). The L</ROW> constant and L</row>
accessor are installed directly into the caller's package by this
helper.

=head1 USAGE

    use Test2::Harness2::Util::DBDelegate $table_name;

C<$table_name> must match the DB row class's L<TABLE>. The DB class
is computed by depluralising the table name (C<ies $<gt> y>,
C<ches $<gt> ch>, then strip a trailing C<s>), then CamelCasing the
remaining snake_case segments, then prepending
C<Test2::Harness2::DB::>:

    schedulers           -> Test2::Harness2::DB::Scheduler
    service_state        -> Test2::Harness2::DB::ServiceState
    resource_snapshots   -> Test2::Harness2::DB::ResourceSnapshot
    job_tries            -> Test2::Harness2::DB::JobTry
    launches             -> Test2::Harness2::DB::Launch
    vcs_info             -> Test2::Harness2::DB::VcsInfo

The conversion lives in L<Test2::Harness2::Util/table_to_db_class>
and is shared with the handle's row-class lookup. The helper croaks
if the DB class cannot be loaded or its C<TABLE> does not equal the
table name passed in.

=head1 WHAT IS INSTALLED IN THE CALLER

=over 4

=item ROW

A constant returning C<'row'> — the hash-key name of the slot that
holds the DB row object. Mirrors the L<Object::HashBase> style for
attribute constants.

=item row

Reader returning C<< $self->{row} >>. Set the slot by passing
C<< row => $db_row >> to the logic class's constructor (whatever
constructor it has — typically HashBase's C<new>, which stores any
hash arg verbatim).

=item TABLE

Class method returning the table name passed to the helper.

=item DB_CLASS

Class method returning the fully-qualified DB class name (e.g.
C<'Test2::Harness2::DB::Scheduler'>).

=item One reader + one setter per column

For every column reported by C<< $db_class->COLUMNS >>, two methods
are installed that touch the row's hash directly:

    sub colname     { $_[0]->{row}->{colname} }
    sub set_colname { $_[0]->{row}->{colname} = $_[1] }

Direct hash access is intentional: the row class's accessors do
nothing more than return the same value, so the extra method-call
hop is pure overhead. The caller never needs to override what a
column reader / setter returns or writes (a column accessor that
transforms the value is a code smell — put the transform on a
separately-named method on the DB row class instead, e.g.
C<pretty_started> alongside C<started>).

If the caller already has a method by that name (e.g. it defined
an override before C<use>'ing this helper), the existing method is
preserved.

=item Symbol-walk delegation of non-column methods

After installing the column methods, the helper walks the DB row
class's symbol table and installs a delegating wrapper for every
remaining sub:

    sub method_name { shift->{row}->method_name(@_) }

This forwards extra row methods (e.g. C<pretty_started>,
C<has_completed>, anything the DB row class defines beyond its
column accessors) to the logic class for free.

Skipped during the walk:

=over 4

=item *

Anything already installed in the caller (caller wins).

=item *

Names starting with C<_> (private).

=item *

All-uppercase identifiers (column constants and other
L<Object::HashBase>-installed compile-time constants).

=item *

Column accessors and C<set_*> setters for known columns (the
direct-access versions are already installed above).

=item *

Declarative class metadata that the row uses to describe itself —
C<TABLE>, C<PRIMARY_KEY>, C<COLUMNS>, C<JSON_COLUMNS>. The logic
class declares its own C<TABLE> / C<DB_CLASS> instead.

=item *

Perl internals and constructor plumbing: C<new>, C<init>, C<can>,
C<isa>, C<DOES>, C<VERSION>, C<import>, C<unimport>, C<DESTROY>,
C<AUTOLOAD>, etc., plus HashBase's C<attr_list> /
C<add_pre_init> / C<add_post_init>.

=back

What B<is> picked up: C<save>, C<refresh>, C<TO_JSON>, and every
user-defined method on the DB row class.

=back

=head1 RATIONALE

External read-only consumers (App::Yath2, reporting tools, the
ultraviewer) import C<Test2::Harness2::DB::*> classes directly and
never see logic methods. Internal mutating callers go through the
logic classes in C<Test2::Harness2::*>. This helper makes the logic
layer's "read a column" path no more verbose than touching the row
directly, while keeping the boundary explicit.

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

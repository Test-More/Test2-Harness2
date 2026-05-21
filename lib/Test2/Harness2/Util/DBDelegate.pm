package Test2::Harness2::Util::DBDelegate;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Test2::Harness2::Util qw/table_to_db_class/;

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

    no strict 'refs';
    no warnings 'redefine';

    *{"${into}::ROW"}      = sub { 'row' };
    *{"${into}::TABLE"}    = sub { $table };
    *{"${into}::DB_CLASS"} = sub { $db_class };
    *{"${into}::row"}      = sub { $_[0]->{row} };

    for my $col ($db_class->COLUMNS) {
        next if defined &{"${into}::${col}"};
        *{"${into}::${col}"} = sub { $_[0]->{row}->$col };
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
        # Read columns via delegate (forwarded to $self->row->...):
        my $runner_id = $self->runner_id;

        # Mutate the row hash directly, then persist:
        $self->row->{some_col} = $new_val;
        $self->row->save;
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

=item One reader per column

For every column reported by C<< $db_class->COLUMNS >>, a reader is
installed that delegates to the row object:

    sub colname { $_[0]->{row}->colname }

If the caller already has a method by that name (e.g. it defined an
override before C<use>'ing this helper), the existing method is
preserved.

Setters are deliberately not installed. Mutate columns by writing
the row's hash directly (C<< $self->row->{col} = $val >>) and then
calling C<< $self->row->save >>; the explicit two-step keeps the
mutation visible at the call site.

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

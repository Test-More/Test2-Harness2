package Test2::Harness2::Launcher::EntryPoint;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use IO::Handle;

use Test2::Harness2;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

our $START_CLASS;

sub install_start_hook {
    my ($class) = @_;
    croak "install_start_hook: class is required" unless $class;
    croak "install_start_hook: already installed for $START_CLASS, cannot also install for $class"
        if $START_CLASS && $START_CLASS ne $class;

    $START_CLASS = $class;
    return;
}

sub fire {
    shift if @_ && !ref($_[0]) && $_[0] && $_[0]->isa(__PACKAGE__);
    my (%extra) = @_;

    my $launcher_class = $extra{class} // $START_CLASS
        or croak "EntryPoint::fire: no launcher class registered (did you use the =start import?)";

    my $spec = $extra{spec} // _read_spec_from_stdin();

    my %connect_args = (project => $spec->{project} // 'harness2');
    if (defined $spec->{path}) {
        $connect_args{path} = $spec->{path};
    }
    elsif (defined $spec->{discovery_path}) {
        $connect_args{path} = $spec->{discovery_path};
    }
    else {
        $connect_args{dsn}    = $spec->{dsn};
        $connect_args{flavor} = $spec->{flavor};
    }
    my $h = Test2::Harness2->connect(%connect_args);

    my %args = (
        handle      => $h,
        launcher_id => $spec->{launcher_id},
    );
    $args{scheduler_pid} = $spec->{scheduler_pid} if defined $spec->{scheduler_pid};

    my $launcher = $launcher_class->new(%args);
    $launcher->run;
    return;
}

sub feed_spec_to {
    my (%args) = @_;
    my $cmd = $args{cmd}  // croak "feed_spec_to: 'cmd' arg required";
    my $spec = $args{spec} // croak "feed_spec_to: 'spec' arg required";

    open(my $fh, '|-', @$cmd)
        or die "Failed to open pipe to @$cmd: $!";
    $fh->autoflush(1);
    print {$fh} encode_json($spec), "\n";
    close($fh);
    return $? >> 8;
}

sub _read_spec_from_stdin {
    local $/;
    my $bytes = <STDIN>;
    croak "No spec read from STDIN" unless defined $bytes && length $bytes;
    my $decoded = eval { decode_json($bytes) };
    croak "Failed to decode launcher spec from STDIN: $@" unless ref($decoded) eq 'HASH';

    croak "Launcher spec is missing 'launcher_id'"
        unless defined $decoded->{launcher_id};
    croak "Launcher spec must include 'path', 'discovery_path' or 'dsn'"
        unless defined $decoded->{path}
            || defined $decoded->{discovery_path}
            || defined $decoded->{dsn};
    return $decoded;
}

INIT {
    if ($START_CLASS && !$ENV{T2_HARNESS2_NO_LAUNCHER_START}) {
        __PACKAGE__->fire;
        exit 0;
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Launcher::EntryPoint - C<=start> import hook plus
the helper a caller uses to feed a launcher its spec.

=head1 DESCRIPTION

Every launcher exposes a small fresh-process recipe:

    perl -MTest2::Harness2::Launcher::ForkExec=start -e '1;'

The C<=start> tag on the C<use> line is honored by the launcher
class's C<import>, which calls L</install_start_hook> with its
own name. An C<INIT> block in this module then reads a launcher
spec from STDIN and runs the launcher's L<run|Test2::Harness2::Role::Service/run>
method.

The launcher spec is a single JSON object on STDIN:

    {
      "discovery_path": "/tmp/...",     # OR dsn + flavor
      "launcher_id":    42,
      "scheduler_pid":  12345           # optional
    }

A helper L</feed_spec_to> on the caller side opens a pipe to the
launcher command, encodes the spec, and closes -- the launcher
process picks it up via its STDIN read.

=head1 CLASS METHODS

=over 4

=item Test2::Harness2::Launcher::EntryPoint->install_start_hook($class)

Register C<$class> as the launcher class the INIT block should
construct. Called by each launcher's C<import> when the caller asks
for C<=start>.

=item Test2::Harness2::Launcher::EntryPoint->fire(%opts)

Read a launcher spec from STDIN (or take C<spec =E<gt> \%s> in
C<%opts>), connect to the harness via L<Test2::Harness2/connect>,
construct the registered launcher class, and call C<run>.

=item $exit = Test2::Harness2::Launcher::EntryPoint::feed_spec_to(
    cmd => \@argv, spec => \%spec)

Caller-side helper: opens a pipe to C<@argv>, sends the JSON spec,
closes the pipe and returns the exit code. Useful in tests and in
the scheduler's launcher-start path.

=back

=head1 ENVIRONMENT

=over 4

=item T2_HARNESS2_NO_LAUNCHER_START

When set, the INIT block does nothing. Useful in test harnesses
that load a launcher class for inspection without wanting it to
fire on their own STDIN.

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

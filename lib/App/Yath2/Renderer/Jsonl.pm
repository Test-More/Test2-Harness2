package App::Yath2::Renderer::Jsonl;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util qw/open_file/;

use parent 'Test2::Harness2::Renderer';
use Test2::Harness2::Util::HashBase qw{
    +fh
    +file
    +last_log
    +opened
    +finished
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Jsonl - Renderer that writes every harness event to a
whole-run jsonl log file.

=head1 DESCRIPTION

This renderer reproduces the old command-level jsonl "logger": it writes each
harness event as one line of JSON (C<< $event->as_json >>) to a file, optionally
bzip2/gzip compressed. It opens the file at construction (or lazily on the first
event), maintains a C<./lastlog.jsonl[.gz|.bz2]> symlink, and on C<finish> writes the
trailing C<null> terminator, closes the file, and prints a "Wrote log file"
message.

The file path + compression are resolved by L<App::Yath2::Options::Logging> (the
C<jsonl> option group) and read from C<< settings->jsonl >>.

=cut

# Resolve the jsonl settings group. The path/compression were resolved by the
# jsonl option group's post_process and stored on settings->jsonl.
sub _jsonl ($self) {
    my $settings = $self->{+SETTINGS} or return undef;
    return undef unless $settings->check_group('jsonl');
    return $settings->jsonl;
}

# Open the log filehandle (plain or compressed) and set up the lastlog symlink.
# Lazy + idempotent: the first event (or start) opens it; later calls are no-ops.
sub _open ($self) {
    return $self->{+FH} if $self->{+OPENED};
    $self->{+OPENED} = 1;

    my $jsonl = $self->_jsonl or return undef;
    my $file = $jsonl->file   or return undef;
    $self->{+FILE} = $file;

    if ($jsonl->bzip2) {
        no warnings 'once';
        require IO::Compress::Bzip2;
        $self->{+FH} = IO::Compress::Bzip2->new($file)
            or die "Could not open log file '$file': $IO::Compress::Bzip2::Bzip2Error";
    }
    elsif ($jsonl->gzip) {
        no warnings 'once';
        require IO::Compress::Gzip;
        $self->{+FH} = IO::Compress::Gzip->new($file)
            or die "Could not open log file '$file': $IO::Compress::Gzip::GzipError";
    }
    else {
        $self->{+FH} = open_file($file, '>');
    }

    # Refresh the lastlog symlink: drop any stale one, then point it at this file.
    # Test with -l (or -e) NOT -f: a dangling symlink (its target was deleted)
    # fails -f but must still be swept, else the symlink() below fails EEXIST.
    for my $ext ('jsonl', 'jsonl.bz2', 'jsonl.gz') {
        my $name = "./lastlog.$ext";
        next unless -l $name || -e $name;
        unlink($name) or warn "Could not unlink '$name': $!";
    }

    if ($file =~ m/\.(jsonl(?:\.(?:bz2|gz))?)$/) {
        my $ext  = $1;
        my $name = "./lastlog.$ext";
        # eval covers symlink-less platforms (symlink dies -> $@); a plain failure
        # (e.g. EEXIST) returns false with no die, so report $! in that case.
        if (eval { symlink($file, $name) }) {
            $self->{+LAST_LOG} = $name;
        }
        else {
            warn "Could not symlink the log file to '$name': " . ($@ || $!);
        }
    }

    return $self->{+FH};
}

# Open the filehandle up front at construction time, matching the old eager
# logger() open in Command::test (the file existed even for an empty run, and the
# "Wrote log file" message + lastlog symlink were unconditional once enabled).
# Lazy _open also covers the first-event path for any caller that skips init.
sub init ($self) {
    $self->_open;
    return;
}

sub render_event ($self, $event) {
    my $fh = $self->_open or return;
    print $fh $event->as_json, "\n";
    return;
}

# End-of-run: write the null terminator, close the file, and report. Idempotent.
sub finish ($self) {
    return if $self->{+FINISHED};
    $self->{+FINISHED} = 1;

    my $fh = $self->{+FH} or return;

    print $fh "null\n";
    # close() is the primary write check for BOTH paths: on the plain path stdio
    # buffering defers per-event write errors (e.g. disk full) to the flush at
    # close, and IO::Compress surfaces flush/trailer errors via close too. A
    # failed close means the archive is corrupt/truncated -- warn and DO NOT print
    # the "Wrote log file" success message that would falsely bless it.
    close($fh) or do {
        warn "Failed writing log file '$self->{+FILE}': $!";
        return;
    };

    my $settings = $self->{+SETTINGS};
    my $quiet    = ($settings && $settings->check_group('display')) ? $settings->display->quiet : 0;
    return if $quiet > 2;

    print "\n";
    print "Wrote log file: " . $self->{+FILE} . "\n";
    print " (Symlinked to: " . $self->{+LAST_LOG} . ")\n" if $self->{+LAST_LOG};

    return;
}

1;

__END__

=pod

=encoding UTF-8

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

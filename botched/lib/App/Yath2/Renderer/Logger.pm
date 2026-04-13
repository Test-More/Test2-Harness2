package App::Yath2::Renderer::Logger;
use strict;
use warnings;

our $VERSION = '2.000012';

use File::Spec;

use POSIX qw/strftime/;

use Test2::Harness2::Util qw/clean_path/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use parent 'App::Yath2::Renderer';
use Test2::Harness2::Util::HashBase qw{
    <file
    <gzip
    <bzip2
    <fh
    <lastlog
};

sub weight { -100 }

sub produces_terminal_output { 0 }

sub start {
    my $self = shift;

    my $fh;
    my $file = $self->file;

    if ($self->bzip2) {
        no warnings 'once';
        require IO::Compress::Bzip2;
        $fh = IO::Compress::Bzip2->new($file) or die "Could not open log file '$file': $IO::Compress::Bzip2::Bzip2Error";
    }
    elsif ($self->gzip) {
        no warnings 'once';
        require IO::Compress::Gzip;
        $fh = IO::Compress::Gzip->new($file) or die "Could not open log file '$file': $IO::Compress::Gzip::GzipError";
    }
    else {
        open($fh, '>', $self->{+FILE}) or die "Could not open log file '$self->{+FILE}': $!";
        $fh->autoflush(1);
    }

    $self->{+FH} = $fh;

    print "Opened log file: $file\n";
}

sub render_event {
    my $self = shift;
    my ($event) = @_;

    print {$self->{+FH}} encode_json($event), "\n";
}

sub finish {
    my $self = shift;
    my ($auditor) = @_;

    print {$self->{+FH}} "null\n";
    close($self->{+FH});

    print "\nWrote log file: $self->{+FILE}\n";

    if ($self->lastlog) {
        for my $ext ('jsonl', 'jsonl.bz2', 'jsonl.gz') {
            my $n0 = "lastlog.${ext}";
            my $n1 = "lastlog-1.${ext}";

            if (-e $n1 || -l $n1) {
                unlink(clean_path($n1));
                unlink($n1);
            }

            rename($n0, $n1) if -e $n0 || -l $n0;
        }

        my $file = $self->{+FILE};
        my $link = $self->_lastlog_link_name;
        unless ($file eq $link) {
            symlink($file => $link) or die "Could not create symlink $file -> $link: $!";
            print "Linked log file: $link\n";
        }
    }
}

sub _lastlog_link_name {
    my $self = shift;

    my $name = 'lastlog.jsonl';
    $name .= '.bz2' if $self->bzip2;
    $name .= '.gz'  if $self->gzip;

    return $name;
}

sub time_for_strftime { time() }

sub expand_log_file_format {
    my ($pattern, $settings) = @_;
    $pattern =~ s{%!(\w)}{_expand($1, $settings)}ge;
    my $res = strftime($pattern, localtime(time_for_strftime()));
    return $res;
}

sub _expand {
    my ($letter, $settings) = @_;

    if ($letter eq "U") {
        return $settings && $settings->can('run') ? $settings->run->run_id : 'NO_RUN_ID';
    }
    elsif ($letter eq "u") { return $ENV{USER} // 'unknown' }
    elsif ($letter eq "p") { return $$ }
    elsif ($letter eq "P") {
        my $project = $settings && $settings->can('yath') ? ($settings->yath->project // '') : '';
        return length($project) ? "${project}~" : "";
    }
    elsif ($letter eq "S") {
        my ($s, $m, $h) = (localtime(time_for_strftime()))[0, 1, 2];
        return sprintf("%05d", $s + 60 * $m + 3600 * $h);
    }
    else {
        return "%!$letter";
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Logger - JSONL event logger with optional compression

=head1 DESCRIPTION

This renderer writes every event as a JSON line to a log file. It supports
optional gzip or bzip2 compression via L<IO::Compress::Gzip> or
L<IO::Compress::Bzip2>. When C<lastlog> is enabled a convenience symlink
is maintained pointing at the most recent log.

=head1 SYNOPSIS

    my $logger = App::Yath2::Renderer::Logger->new(
        file => '/tmp/test.jsonl',
    );

    $logger->start;
    $logger->render_event($event);
    $logger->finish;

=head1 ATTRIBUTES

=over 4

=item file

Path to the log file.

=item gzip

Enable gzip compression (requires L<IO::Compress::Gzip>).

=item bzip2

Enable bzip2 compression (requires L<IO::Compress::Bzip2>).

=item fh

The open filehandle (set by C<start()>).

=item lastlog

If true, create a C<lastlog.jsonl[.gz|.bz2]> symlink after finishing.

=back

=head1 METHODS

=over 4

=item $logger->start()

Opens the log file (with compression if requested).

=item $logger->render_event($event)

Writes the event as a JSON line.

=item $logger->finish()

Writes a final C<null> line, closes the file, and optionally creates the
lastlog symlink.

=item $n = $logger->weight()

Returns -100 (highest priority).

=item $bool = $logger->produces_terminal_output()

Returns 0.

=item $filename = expand_log_file_format($pattern, $settings)

Expands strftime sequences and custom C<%!> escapes in C<$pattern>.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

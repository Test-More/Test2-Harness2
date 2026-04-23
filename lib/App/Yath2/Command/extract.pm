package App::Yath2::Command::extract;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Path qw/make_path/;
use File::Spec ();
use File::Basename qw/dirname/;

use App::Yath2::LogArchive;

use Object::HashBase qw/<settings <args <env_vars <option_state <plugins/;

use Getopt::Yath;

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub group { 'log parsing' }

sub summary  { "Extract a yath log archive" }
sub cli_args { "[--] archive_filename [destination]" }

sub description {
    return <<"    EOT";
Extract a yath log archive into a directory.

Required first argument: path to the archive file.

Optional second argument: destination directory. Defaults to './logs'.
The destination must NOT already exist; it will be created (along with
any missing parents) before extraction.

For tar.zidx archives the per-file zstd compression is reversed during
extraction, so the on-disk output matches the original log directory
byte-for-byte.
    EOT
}

sub args_include_tests { 0 }

sub run {
    my $self = shift;

    my $args = $self->args;
    shift @$args if @$args && $args->[0] eq '--';

    my $archive = shift @$args;
    die "archive_filename is required\n"
        unless defined $archive && length $archive;
    die "archive '$archive' does not exist\n" unless -e $archive;

    my $dest = shift @$args // './logs';

    die "extra arguments after destination\n" if @$args;

    die "destination '$dest' already exists\n" if -e $dest;

    make_path($dest) or die "could not create destination '$dest': $!\n"
        unless -d $dest;

    my $la = App::Yath2::LogArchive->new(path => $archive);

    print "Extracting '$archive' to '$dest' (format: " . _format_for($la) . ")\n";

    my $count = 0;
    for my $rel ($la->list_files) {
        my $abs    = File::Spec->catfile($dest, $rel);
        my $parent = dirname($abs);
        make_path($parent) unless -d $parent;

        my $rfh = $la->read_file($rel);
        open(my $out, '>', $abs) or die "open $abs: $!\n";
        binmode $out;
        binmode $rfh;
        my $buf;
        while (read($rfh, $buf, 65536)) {
            print $out $buf;
        }
        close $out  or die "close $abs: $!\n";
        close $rfh;
        $count++;
    }

    print "Extracted $count file(s)\n";
    return 0;
}

sub _format_for {
    my ($la) = @_;
    my $class = ref $la;
    return $class =~ s/^App::Yath2::LogArchive:://r;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

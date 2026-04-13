package Test2::Harness2::Util;
use strict;
use warnings;

use Cwd qw/realpath/;
use Carp qw/confess croak/;
use Fcntl qw/LOCK_EX LOCK_UN :mode/;
use Test2::Util qw/try_sig_mask do_rename/;

use File::Spec;

our $VERSION = '2.000012';

use Exporter 'import';

our @EXPORT_OK = qw{
    find_libraries
    mod2file
    file2mod
    fqmod
    parse_exit
    hub_truth
    apply_encoding
    chmod_tmp

    maybe_open_file
    maybe_read_file
    open_file
    read_file
    write_file
    write_file_atomic
    lock_file
    unlock_file

    hash_purge

    is_same_file

    clean_path
    find_in_updir
};

sub clean_path {
    my ($path, $absolute) = @_;

    confess "No path was provided to clean_path()" unless $path;

    $absolute //= 1;
    $path = realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
}

sub find_in_updir {
    my $path = shift;
    return clean_path($path) if -e $path;

    my %seen;
    while (1) {
        $path = File::Spec->catdir('..', $path);
        my $check;
        my $ok  = eval { $check = realpath(File::Spec->rel2abs($path)); 1 };
        my $err = $@;
        last unless $ok && $check;
        last          if $seen{$check}++;
        return $check if -e $check;
    }

    return;
}

sub is_same_file {
    my ($file1, $file2) = @_;

    return 0 unless defined $file1;
    return 0 unless defined $file2;

    return 1 if "$file1" eq "$file2";
    return 1 if clean_path($file1) eq clean_path($file2);

    return 0 unless -e $file1;
    return 0 unless -e $file2;

    my ($dev1, $inode1) = stat($file1);
    my ($dev2, $inode2) = stat($file2);

    return 0 unless $dev1 == $dev2;
    return 0 unless $inode1 == $inode2;
    return 1;
}

sub hash_purge {
    my ($hash) = @_;

    my $keep = 0;

    for my $key (keys %$hash) {
        my $val = $hash->{$key};

        my $delete = 0;
        $delete = 1 unless defined($val);
        $delete ||= ref($hash->{$key}) eq 'HASH' && !hash_purge($hash->{$key});

        if ($delete) {
            delete $hash->{$key};
            next;
        }

        $keep++;
    }

    return $keep;
}

sub chmod_tmp {
    my $file = shift;

    my $mode = S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO;

    chmod($mode, $file);
}

sub apply_encoding {
    my ($fh, $enc) = @_;
    return unless $enc;

    # https://rt.perl.org/Public/Bug/Display.html?id=31923
    # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
    # order to avoid the thread segfault.
    return binmode($fh, ":utf8") if $enc =~ m/^utf-?8$/i;
    binmode($fh, ":encoding($enc)");
}

sub parse_exit {
    my ($exit) = @_;
    croak "an exit value is required" unless defined $exit;

    my $sig = $exit & 127;
    my $dmp = $exit & 128;

    return {
        sig => $sig,
        err => ($exit >> 8),
        dmp => $dmp,
        all => $exit,
    };
}

sub hub_truth {
    my ($f) = @_;

    return $f->{hubs}->[0] if $f->{hubs} && @{$f->{hubs}};
    return $f->{trace}     if $f->{trace};
    return {};
}

sub fqmod {
    my ($input, $prefixes, %options) = @_;

    croak "At least 1 prefix is required" unless $prefixes;

    $prefixes = [$prefixes] unless ref($prefixes) eq 'ARRAY';

    croak "At least 1 prefix is required" unless @$prefixes;
    croak "Cannot use no_require when providing multiple prefixes" if $options{no_require} && @$prefixes > 1;

    if ($input =~ m/^\+(.*)$/) {
        my $mod = $1;
        return $mod if $options{no_require};
        return $mod if eval { require(mod2file($mod)); 1 };
        confess($@);
    }

    my %tried;
    for my $pre (@$prefixes) {
        my $mod = $input =~ m/^\Q$pre\E/ ? $input : "$pre\::$input";

        if ($options{no_require}) {
            return $mod;
        }
        else {
            return $mod if eval { require(mod2file($mod)); 1 };
            ($tried{$mod}) = split /\n/, $@;
            $tried{$mod} =~ s{^(Can't locate \S+ in \@INC).*$}{$1.};
        }
    }

    my @caller = caller;

    die "Could not locate a module matching '$input' at $caller[1] line $caller[2], the following were checked:\n" . join("\n", map { " * $_: $tried{$_}" } sort keys %tried) . "\n";
}

sub file2mod {
    my $file = shift;
    my $mod  = $file;
    $mod =~ s{/}{::}g;
    $mod =~ s/\..*$//;
    return $mod;
}

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

sub find_libraries {
    my ($search, @paths) = @_;
    my @parts = grep $_, split /::(\*)?/, $search;

    @paths = @INC unless @paths;

    @paths = map { File::Spec->canonpath($_) } @paths;

    my %prefixes = map { $_ => 1 } @paths;

    my @found;
    my @bases = ([map { [$_ => length($_)] } @paths]);
    while (my $set = shift @bases) {
        my $new_base = [];
        my $part     = shift @parts;

        for my $base (@$set) {
            my ($dir, $prefix) = @$base;
            if ($part ne '*') {
                my $path = File::Spec->catdir($dir, $part);
                if (@parts) {
                    push @$new_base => [$path, $prefix] if -d $path;
                }
                elsif (-f "$path.pm") {
                    push @found => ["$path.pm", $prefix];
                }

                next;
            }

            opendir(my $dh, $dir) or next;
            for my $item (readdir($dh)) {
                next if $item =~ m/^\./;
                my $path = File::Spec->catdir($dir, $item);
                if (@parts) {
                    # Sometimes @INC dirs are nested in each other.
                    next if $prefixes{$path};

                    push @$new_base => [$path, $prefix] if -d $path;
                    next;
                }

                next unless -f $path && $path =~ m/\.pm$/;
                push @found => [$path, $prefix];
            }
        }

        push @bases => $new_base if @$new_base;
    }

    my %out;
    for my $found (@found) {
        my ($path, $prefix) = @$found;

        my @file_parts = File::Spec->splitdir(substr($path, $prefix));
        shift @file_parts if $file_parts[0] eq '';

        my $file = join '/' => @file_parts;
        $file_parts[-1] = substr($file_parts[-1], 0, -3);
        my $module = join '::' => @file_parts;

        $out{$module} //= $file;
    }

    return \%out;
}

sub maybe_read_file {
    my ($file) = @_;
    return undef unless -f $file;
    return read_file($file);
}

sub read_file {
    my ($file, @args) = @_;

    my $fh = open_file($file, '<', @args);
    local $/;
    my $out = <$fh>;
    close_file($fh, $file);

    return $out;
}

sub write_file {
    my ($file, @content) = @_;

    my $fh = open_file($file, '>');
    print $fh @content;
    close_file($fh, $file);

    return @content;
}

my %COMPRESSION = (
    bz2 => {module => 'IO::Uncompress::Bunzip2', errors => \$IO::Uncompress::Bunzip2::Bunzip2Error},
    gz  => {module => 'IO::Uncompress::Gunzip',  errors => \$IO::Uncompress::Gunzip::GunzipError},
);

sub open_file {
    my ($file, $mode, %opts) = @_;
    $mode ||= '<';

    unless ($opts{no_decompress}) {
        if (my $ext = $opts{ext}) {
            $opts{compression} //= $COMPRESSION{$ext} or die "Unknown compression: $ext";
        }

        if ($file =~ m/\.(gz|bz2)$/i) {
            my $ext = lc($1);
            $opts{compression} //= $COMPRESSION{$ext} or die "Unknown compression: $ext";
        }

        if ($mode eq '<' && $opts{compression}) {
            my $spec = $opts{compression};
            my $mod  = $spec->{module};
            require(mod2file($mod));

            my $fh = $mod->new($file) or die "Could not open file '$file' ($mode): ${$spec->{errors}}";
            return $fh;
        }
    }

    open(my $fh, $mode, $file) or confess "Could not open file '$file' ($mode): $!";
    return $fh;
}

sub maybe_open_file {
    my ($file, $mode) = @_;
    return undef unless -f $file;
    return open_file($file, $mode);
}

sub close_file {
    my ($fh, $name) = @_;
    return if close($fh);
    confess "Could not close file: $!" unless $name;
    confess "Could not close file '$name': $!";
}

sub write_file_atomic {
    my ($file, @content) = @_;

    my $pend = "$file.pend";

    my ($ok, $err) = try_sig_mask {
        write_file($pend, @content);
        my ($ren_ok, $ren_err) = do_rename($pend, $file);
        die "$pend -> $file: $ren_err" unless $ren_ok;
    };

    die $err unless $ok;

    return @content;
}

sub lock_file {
    my ($file, $mode) = @_;

    my $fh;
    if (ref $file) {
        $fh = $file;
    }
    else {
        open($fh, $mode // '>>', $file) or die "Could not open file '$file': $!";
    }

    for (1 .. 21) {
        flock($fh, LOCK_EX) and last;
        die "Could not lock file (try $_): $!" if $_ >= 20;
        next                                   if $!{EINTR} || $!{ERESTART};
        die "Could not lock file: $!";
    }

    return $fh;
}

sub unlock_file {
    my ($fh) = @_;
    for (1 .. 21) {
        flock($fh, LOCK_UN) and last;
        die "Could not unlock file (try $_): $!" if $_ >= 20;
        next                                     if $!{EINTR} || $!{ERESTART};
        die "Could not unlock file: $!";
    }

    return $fh;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util - Utility functions for Test2::Harness2

=head1 DESCRIPTION

Collection of utility functions used throughout Test2::Harness2.

=head1 SYNOPSIS

    use Test2::Harness2::Util qw/parse_exit mod2file file2mod hub_truth clean_path/;

=head1 EXPORTS

All exports are optional.

=over 4

=item parse_exit($exit)

Parse an exit value into its components. Returns a hashref with keys:
C<sig> (signal number, bits 0-6), C<dmp> (core dump flag, bit 7),
C<err> (exit code, bits 8+), C<all> (original value).

=item mod2file($module)

Convert a module name like C<Foo::Bar> to a file path like C<Foo/Bar.pm>.

=item file2mod($file)

Convert a file path like C<Foo/Bar.pm> to a module name like C<Foo::Bar>.

=item fqmod($input, $prefixes, %options)

Fully qualify a module name using the provided prefixes.

=item hub_truth($facets)

Given a facets hashref, return the hub (C<hubs->[0]>), or trace, or an empty
hashref.

=item apply_encoding($fh, $enc)

Apply an encoding to a filehandle.

=item chmod_tmp($file)

Chmod a file with sticky bit and world read/write/execute permissions (suitable
for temp directories).

=item open_file($file, $mode, %opts)

Open a file, with optional decompression support for .gz and .bz2 files.

=item maybe_open_file($file, $mode)

Open a file only if it exists. Returns undef otherwise.

=item read_file($file)

Read and return the entire contents of a file.

=item maybe_read_file($file)

Read a file only if it exists. Returns undef otherwise.

=item write_file($file, @content)

Write content to a file.

=item write_file_atomic($file, @content)

Write content to a file atomically (write to .pend then rename).

=item lock_file($file, $mode)

Open and exclusively lock a file. Returns the filehandle.

=item unlock_file($fh)

Unlock a previously locked file.

=item hash_purge($hash)

Remove undefined values and empty hashrefs from a hash in-place.
Returns the count of remaining defined values.

=item is_same_file($file1, $file2)

Return true if two paths refer to the same file (by path comparison or
inode comparison).

=item clean_path($path, $absolute)

Resolve and clean a path. By default makes it absolute via C<realpath>.

=item find_in_updir($path)

Search for a path in the current directory and each parent directory.

=item find_libraries($search, @paths)

Find Perl modules matching a search pattern (supports C<*> glob).
Returns a hashref of module_name => relative_file.

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

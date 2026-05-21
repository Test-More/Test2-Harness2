package Test2::Harness2::Util;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak confess/;
use Cwd qw/realpath/;
use Fcntl qw/LOCK_EX LOCK_UN O_WRONLY O_CREAT O_EXCL/;
use File::Spec;
use Importer Importer             => 'import';
use Importer 'Test2::Util::Times' => qw/render_duration/;
use Test2::Util qw/try_sig_mask do_rename/;
use Test2::Util::UUID qw/looks_like_uuid/;

our @EXPORT_OK = qw{
    apply_encoding
    clean_path
    close_file
    find_libraries
    fqmod
    hub_truth
    load_module
    lock_file
    looks_like_uuid
    maybe_open_file
    maybe_read_file
    mod2file
    open_file
    read_file
    render_duration
    table_to_db_class
    unlock_file
    write_file
    write_file_atomic
    write_file_atomic_mode
};

sub table_to_db_class {
    my ($table) = @_;
    my $depluralized = $table;
    $depluralized =~ s/ies$/y/  ||
    $depluralized =~ s/ches$/ch/ ||
    $depluralized =~ s/s$//;

    my $stem = join('', map { ucfirst $_ } split /_/, $depluralized);
    return "Test2::Harness2::DB::$stem";
}

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util - Small shared utility functions used across the harness.

=head1 DESCRIPTION

A grab-bag of helpers used across L<Test2::Harness2>: module-name handling,
filesystem reads and writes (including atomic replace), advisory locking,
encoding application, and Test2 facet-data helpers.

=head1 SYNOPSIS

    use Test2::Harness2::Util qw/mod2file hub_truth/;

    my $file  = mod2file('Foo::Bar');         # 'Foo/Bar.pm'
    my $hub   = hub_truth($facet_data);

=head1 EXPORTS

All exports are optional and must be requested explicitly.

=cut

=over 4

=item apply_encoding

=item apply_encoding($fh, $encoding)

Apply C<$encoding> to C<$fh> via C<binmode>. Returns immediately when
C<$encoding> is false. Uses C<:utf8> for any C<utf-?8> spelling to avoid the
thread segfault from C<:encoding(utf8)>; any other encoding goes through
C<:encoding($encoding)>.

=back

=cut

sub apply_encoding {
    my ($fh, $enc) = @_;
    return unless $enc;

    return binmode($fh, ":utf8") if $enc =~ m/^utf-?8$/i;
    binmode($fh, ":encoding($enc)");
}

=over 4

=item close_file

=item close_file($fh)

=item close_file($fh, $name)

Wrap C<close()> with a clearer diagnostic. The optional C<$name> is
included in the error when close fails.

=back

=cut

sub close_file {
    my ($fh, $name) = @_;
    return if close($fh);
    confess "Could not close file: $!" unless $name;
    confess "Could not close file '$name': $!";
}

=over 4

=item hub_truth

=item $facet = hub_truth($facet_data)

Return the authoritative hub/trace facet from a Test2 facet-data hash.
Prefers C<< $facet_data->{hubs}->[0] >> when present, falls back to
C<< $facet_data->{trace} >>, and returns an empty hashref if neither
is populated.

=back

=cut

sub hub_truth {
    my ($f) = @_;

    return $f->{hubs}->[0] if $f->{hubs} && @{$f->{hubs}};
    return $f->{trace}     if $f->{trace};
    return {};
}

=over 4

=item mod2file

=item $path = mod2file($module_name)

Convert a module name (C<Foo::Bar::Baz>) to its C<%INC>-style relative
path (C<Foo/Bar/Baz.pm>). Confesses if the module name is empty.

=back

=cut

sub mod2file {
    my ($mod) = @_;
    confess "No module name provided" unless $mod;
    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    return $file;
}

=over 4

=item clean_path

=item $abs = clean_path($path)

=item $abs = clean_path($path, $absolute)

Return an absolute form of C<$path>. With C<$absolute> true (the
default) the path is first run through L<Cwd/realpath> to resolve
symlinks, then through L<< File::Spec/rel2abs >>. Pass a false
C<$absolute> to skip the C<realpath> step. Confesses when C<$path>
is empty.

=back

=cut

sub clean_path {
    my ($path, $absolute) = @_;

    confess "No path was provided to clean_path()" unless $path;

    $absolute //= 1;
    $path = realpath($path) // $path if $absolute;

    return File::Spec->rel2abs($path);
}

=over 4

=item load_module

=item $name = load_module($module_name)

Load C<$module_name> via C<require>, idempotently. Short-circuits when
C<%INC> already records the file or the package stash is populated.
Returns the module name on success; propagates the underlying
C<require> exception on failure.

=back

=cut

sub load_module {
    my ($name) = @_;
    croak "load_module: module name is required"
        unless defined $name && length $name;

    my $file = mod2file($name);
    return $name if $INC{$file};
    {
        no strict 'refs';
        return $name if %{"${name}::"};
    }
    require $file;
    return $name;
}

=over 4

=item fqmod

=item $mod = fqmod($input, $prefix)

=item $mod = fqmod($input, \@prefixes, %options)

Resolve a short module name C<$input> against one or more namespace
prefixes, returning the fully qualified module name. A leading C<'+'>
on C<$input> bypasses the prefixes and treats the remainder as an
absolute module name. Otherwise each prefix is tried in order and the
first that successfully C<require>s wins; an C<$input> that already
starts with one of the prefixes is used as-is.

Options:

=over 4

=item no_require

Skip the C<require> step and return the resolved name without loading
the module. Only legal with a single prefix.

=back

Dies with a multi-line diagnostic listing each candidate when no
prefix resolves.

=back

=cut

sub fqmod {
    my ($input, $prefixes, %options) = @_;

    croak "At least 1 prefix is required" unless $prefixes;

    $prefixes = [$prefixes] unless ref($prefixes) eq 'ARRAY';

    croak "At least 1 prefix is required" unless @$prefixes;
    croak "Cannot use no_require when providing multiple prefixes"
        if $options{no_require} && @$prefixes > 1;

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

=over 4

=item find_libraries

=item $modules = find_libraries($search)

=item $modules = find_libraries($search, @paths)

Search for C<.pm> files matching the namespace pattern C<$search>
under C<@paths> (defaults to C<@INC>). C<$search> is a C<::>-separated
pattern; a C<*> segment is a wildcard at that level. Returns a
hashref mapping each discovered module name to its file path relative
to the matching search root. Nested C<@INC> entries are not
double-traversed.

=back

=cut

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
            $new_base = _find_libraries_step($dir, $prefix, $part, \@parts, \%prefixes, \@found, $new_base);
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

sub _find_libraries_step {
    my ($dir, $prefix, $part, $rem, $prefixes, $found, $new_base) = @_;

    if ($part ne '*') {
        my $path = File::Spec->catdir($dir, $part);
        if (@$rem) {
            push @$new_base => [$path, $prefix] if -d $path;
        }
        elsif (-f "$path.pm") {
            push @$found => ["$path.pm", $prefix];
        }
        return $new_base;
    }

    opendir(my $dh, $dir) or return $new_base;
    for my $item (readdir($dh)) {
        next if $item =~ m/^\./;
        my $path = File::Spec->catdir($dir, $item);
        if (@$rem) {
            next if $prefixes->{$path};
            push @$new_base => [$path, $prefix] if -d $path;
            next;
        }

        next unless -f $path && $path =~ m/\.pm$/;
        push @$found => [$path, $prefix];
    }
    closedir($dh);
    return $new_base;
}

my %COMPRESSION = (
    bz2 => {module => 'IO::Uncompress::Bunzip2', errors => \$IO::Uncompress::Bunzip2::Bunzip2Error},
    gz  => {module => 'IO::Uncompress::Gunzip',  errors => \$IO::Uncompress::Gunzip::GunzipError},
);

=over 4

=item open_file

=item $fh = open_file($path)

=item $fh = open_file($path, $mode)

=item $fh = open_file($path, $mode, %opts)

Open C<$path> and return the handle. The default mode is C<< '<' >>.
When opening for read, C<.gz> / C<.bz2> extensions trigger transparent
decompression via L<IO::Uncompress::Gunzip> / L<IO::Uncompress::Bunzip2>;
pass C<< no_decompress => 1 >> to disable that, or C<< ext => 'gz' >>
/ C<< ext => 'bz2' >> to force compression when the filename does not
carry the usual extension.

Confesses on failure.

=back

=cut

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

=over 4

=item maybe_open_file

=item $fh = maybe_open_file($path)

=item $fh = maybe_open_file($path, $mode)

Like L</open_file>, but returns C<undef> when C<$path> is not a
regular file instead of raising an exception.

=back

=cut

sub maybe_open_file {
    my ($file, $mode) = @_;
    return undef unless -f $file;
    return open_file($file, $mode);
}

=over 4

=item read_file

=item $content = read_file($path, %open_opts)

Slurp C<$path> in full. Extra options are passed through to
L</open_file>. Dies on I/O failure.

=back

=cut

sub read_file {
    my ($file, @args) = @_;

    my $fh = open_file($file, '<', @args);
    local $/;
    my $out = <$fh>;
    close_file($fh, $file);

    return $out;
}

=over 4

=item maybe_read_file

=item $content = maybe_read_file($path)

Like L</read_file>, but returns C<undef> when C<$path> is not a
regular file.

=back

=cut

sub maybe_read_file {
    my ($file) = @_;
    return undef unless -f $file;
    return read_file($file);
}

=over 4

=item write_file

=item write_file($path, @content)

Open C<$path> for write, print C<@content>, and close. Dies on I/O
failure. For crash-safe writes use L</write_file_atomic>.

=back

=cut

sub write_file {
    my ($file, @content) = @_;

    my $fh = open_file($file, '>');
    print $fh @content;
    close_file($fh, $file);

    return @content;
}

=over 4

=item lock_file

=item $fh = lock_file($path_or_fh)

=item $fh = lock_file($path, $mode)

Acquire an exclusive advisory lock via C<flock(LOCK_EX)>. Accepts
either a filename (opened in C<< '>>' >> mode unless C<$mode> is
supplied) or an already-open handle. Retries up to 20 times on
C<EINTR>/C<ERESTART>. Returns the locked handle; pair with
L</unlock_file> (or close the handle) to release.

=back

=cut

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

=over 4

=item unlock_file

=item unlock_file($fh)

Release an advisory lock acquired via L</lock_file>. Retries on
C<EINTR>/C<ERESTART> the same way as acquisition.

=back

=cut

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

=over 4

=item write_file_atomic

=item write_file_atomic($path, @content)

Write C<@content> to C<$path> atomically: writes to C<"$path.pend">
first, then C<do_rename()>s it over the target under a signal mask so
an interrupt cannot leave a half-written file in place. Dies on I/O
failure; the pending file is removed on error.

=back

=cut

sub write_file_atomic {
    my ($file, @content) = @_;

    my $pend = "$file.pend";

    my ($ok, $err) = try_sig_mask {
        write_file($pend, @content);
        my ($ren_ok, $ren_err) = do_rename($pend, $file);
        die "$pend -> $file: $ren_err" unless $ren_ok;
    };

    unless ($ok) {
        unlink($pend);
        die $err;
    }

    return @content;
}

=over 4

=item write_file_atomic_mode

=item write_file_atomic_mode($path, $mode, @content)

L</write_file_atomic> with explicit POSIX mode bits on the result
file. The mode is enforced by C<sysopen>ing the pending file under
C<umask 0> and then C<chmod>ing it before the rename, so the final
file has exactly C<$mode> regardless of the caller's umask.

=back

=cut

sub write_file_atomic_mode {
    my ($file, $mode, @content) = @_;

    croak "write_file_atomic_mode: 'mode' must be defined"
        unless defined $mode;

    my $pend = "$file.pend";

    my ($ok, $err) = try_sig_mask {
        my $old_umask = umask 0;
        my $created   = sysopen(my $fh, $pend, O_WRONLY | O_CREAT | O_EXCL, $mode);
        my $serr      = $!;
        umask $old_umask;
        die "open '$pend' for write: $serr" unless $created;

        print {$fh} @content;
        close_file($fh, $pend);

        chmod($mode, $pend) or die sprintf("chmod 0%o '$pend': $!", $mode);

        my ($ren_ok, $ren_err) = do_rename($pend, $file);
        die "$pend -> $file: $ren_err" unless $ren_ok;
    };

    unless ($ok) {
        unlink($pend);
        die $err;
    }

    return @content;
}

1;

__END__

=pod

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

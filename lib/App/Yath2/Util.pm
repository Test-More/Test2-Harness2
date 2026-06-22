package App::Yath2::Util;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec;
use File::ShareDir();
use Sys::Hostname qw/hostname/;

use Test2::Harness2::Util qw/clean_path/;

use Cwd qw/realpath/;
use Importer Importer => 'import';
use Config qw/%Config/;
use Carp qw/croak/;

our @EXPORT_OK = qw{
    find_runner_link
    find_in_updir
    is_generated_test_pl
    fit_to_width
    isolate_stdout
    find_yath
    share_dir
    share_file
};

sub share_file {
    my ($file) = @_;

    # Prefer the in-repo share/ dir during development.
    my $path = "share/$file";
    return $path if -d 'share' && -f $path;

    return File::ShareDir::dist_file('Test2-Harness2' => $file);
}

sub share_dir {
    my ($dir) = @_;

    # Prefer the in-repo share/ dir during development.
    my $path = "share/$dir";
    return $path if -d $path;

    my $root = File::ShareDir::dist_dir('Test2-Harness2');

    $path = "$root/$dir";

    croak "Could not find '$dir'" unless -d $path;

    return $path;
}

sub find_yath {
    return $App::Yath::Script::SCRIPT if defined $App::Yath::Script::SCRIPT;

    if (-d 'scripts') {
        my $script = File::Spec->catfile('scripts', 'yath');
        return $App::Yath::Script::SCRIPT = clean_path($script) if -e $script && -x $script;
    }

    my @keys = qw{
        bin binexp initialinstalllocation installbin installscript
        installsitebin installsitescript installusrbinperl installvendorbin
        scriptdir scriptdirexp sitebin sitebinexp sitescript sitescriptexp
        vendorbin vendorbinexp
    };

    my %seen;
    for my $path (@Config{@keys}) {
        next unless $path;
        next if $seen{$path}++;

        my $script = File::Spec->catfile($path, 'yath');
        next unless -f $script && -x $script;

        $App::Yath::Script::SCRIPT = $script = clean_path($script);
        return $script;
    }

    die "Could not find yath in Config paths";
}

sub isolate_stdout {
    # Make $fh point at STDOUT, it is our primary output
    open(my $fh, '>&', STDOUT) or die "Could not clone STDOUT: $!";
    select $fh;
    $| = 1;

    # re-open STDOUT redirected to STDERR
    open(STDOUT, '>&', STDERR) or die "Could not redirect STDOUT to STDERR: $!";
    select STDOUT;
    $| = 1;

    # Yes, we want to keep STDERR selected
    select STDERR;
    $| = 1;

    return $fh;
}

sub is_generated_test_pl {
    my ($file) = @_;

    open(my $fh, '<', $file) or die "Could not open '$file': $!";

    my $count = 0;
    while (my $line = <$fh>) {
        last if $count++ > 5;
        next unless $line =~ m/^# THIS IS A GENERATED YATH RUNNER TEST$/;
        return 1;
    }

    return 0;
}


sub find_in_updir {
    my $path = shift;
    return clean_path($path) if -f $path;

    my %seen;
    while(1) {
        $path = File::Spec->catdir('..', $path);
        my $check = eval { realpath(File::Spec->rel2abs($path)) };
        last unless $check;
        last if $seen{$check}++;
        return $check if -f $check;
    }

    return;
}

# Absolute path of a discovery symlink at $dir/$name. The directory is realpath'd
# (safe -- it is a real dir), but the basename is appended WITHOUT resolving it:
# realpath on the symlink itself would follow it to its target (the socket), and
# the caller needs the link path, not the socket. Returns undef if the dir cannot
# be resolved.
sub _abs_link_path {
    my ($dir, $name) = @_;
    my $abs_dir = realpath(File::Spec->rel2abs($dir)) // return;
    return File::Spec->catfile($abs_dir, $name);
}

# Like find_in_updir, but for a symlink (the discovery symlink). realpath in
# find_in_updir resolves the link to its target, so it cannot match a symlink; we
# walk the directory tree upward and test -l on $dir/$name at each level, returning
# the link path itself (not its target).
sub _find_link_in_updir {
    my ($name) = @_;

    my $dir = eval { realpath(File::Spec->rel2abs('.')) } or return;

    my %seen;
    while (defined $dir && length $dir && !$seen{$dir}++) {
        my $link = File::Spec->catfile($dir, $name);
        return $link if -l $link;

        my $parent = realpath(File::Spec->catdir($dir, '..')) // last;
        last if $parent eq $dir;    # reached the filesystem root
        $dir = $parent;
    }

    return;
}

sub _runner_link_existsp {
    my ($path) = @_;
    # A live OR dangling symlink both count as "present" for discovery purposes:
    # dangling means a runner crashed without cleanup, and the caller still wants
    # to find (and clean) it. -l alone catches a dangling link; -e catches a
    # link resolving to a live socket.
    return -l $path || -e $path;
}

# Resolve the discovery symlink path for the current settings. The basename is
# project-prefixed (and host/user-prefixed) so distinct projects/users/hosts get
# distinct symlinks under a shared dir -- the multiple-harness-per-project story
# carried over from the old pfile naming. The extension is plain ".sock" (a
# symlink to runner.socket), not ".json": this is a symlink, not a metadata
# document. Liveness is NOT checked here (a socket connect in App::Yath2::Discovery
# is the live check); this only locates the path.
sub find_runner_link {
    my ($settings, %params) = @_;

    croak "Settings is a required argument" unless $settings;

    # First do the entire search without vivify; only fall through to the
    # vivify-chosen path when nothing already exists.
    if ($params{vivify}) {
        my $found = find_runner_link($settings, %params, vivify => 0);
        return $found if $found;
    }

    my $yath = $settings->harness;

    if (my $link = $yath->persist_file) {
        return $link if _runner_link_existsp($link) || $params{vivify};

        return; # Specified, but not found and no vivify
    }

    my $basename = "yath-runner.sock";
    my $user     = $ENV{USER};
    my $hostname = hostname();
    my $project  = $yath->project;

    my @names = ($basename);
    @names = (@names, map { "$project-$_" } @names) if $project;
    @names = (@names, map { "$hostname-$_" } @names) if $hostname;
    @names = (@names, map { "$user-$_" } @names) if $user;
    @names = reverse map { ".$_" } @names;

    my $set_dir = $yath->persist_dir // $ENV{YATH_PERSISTENCE_DIR};
    my $dir = $set_dir // $ENV{TMPDIR} // $ENV{TEMPDIR} // File::Spec->tmpdir;

    # If a dir was specified, or if the current dir is not writable then we must use $dir/$name
    if ($project || $set_dir || !-w '.') {
        for my $name (@names) {
            my $link = _abs_link_path($dir, $name);
            return $link if _runner_link_existsp($link);
        }

        return _abs_link_path($dir, $names[0]) if $params{vivify};
        return; # Not found
    }

    # Fall back to using the current dir (which must be writable)
    for my $name (@names) {
        my $link = _find_link_in_updir($name);
        return $link if $link;
    }

    # Creating it here!
    return _abs_link_path('.', $names[0]) if $params{vivify};

    # Nope, nothing.
    return;
}

sub fit_to_width {
    my ($width, $join, $text) = @_;

    my @parts = ref($text) ? @$text : split /\s+/, $text;

    my @out;

    my $line = "";
    for my $part (@parts) {
        my $new = $line ? "$line$join$part" : $part;

        if ($line && length($new) > $width) {
            push @out => $line;
            $line = $part;
        }
        else {
            $line = $new;
        }
    }
    push @out => $line if $line;

    return join "\n" => @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Util - General utilities for yath that do not fit anywhere else.

=head1 DESCRIPTION

This package exports several tools used throughout yath that did not fit into
any other package.

=head1 SYNOPSIS

    use App::Yath2::Util qw{
        find_runner_link
        find_in_updir
        is_generated_test_pl
        fit_to_width
        isolate_stdout
        find_yath
        share_dir
        share_file
    };

=head1 EXPORTS

Note that nothing is exported by default, you must request each function to
import.

=over 4

=item $path_to_link = find_runner_link($settings, %params)

The first argument must be an instance of L<Getopt::Yath::Settings>.

Resolve the path of the well-known discovery B<symlink> for the current settings
(the link that points at a persistent runner's C<runner.socket>). The path is
chosen by the same project-prefix / tempdir-vs-cwd rules the old persistence file
used, so distinct projects/users/hosts get distinct symlinks.

When C<vivify> is true the path to use is returned even when nothing exists yet,
so the caller can create the symlink there. Without C<vivify> a path is returned
only when a symlink (live or dangling) already exists.

This only locates the path; it does not check whether the runner is alive --
liveness is a socket connect, handled by L<App::Yath2::Discovery>.

=item $path_to_file = find_in_updir($file_name)

Look for C<$file_name> in the current directory or any parent directory.

=item $bool = is_generated_test_pl($path_to_test_file)

Check if the specified test file was generated by the C<yath init> command.

=item fit_to_width($width, $join, $text)

This will split the C<$text> on space, and then recombine it using C<$join>
inserting newlines as necessary in an attempt to fit the text into C<$width>
horizontal characters. If any words are larger than C<$width> they will not be
split and text-wrapping may occur if used for terminal display.

=item $stdout = isolate_stdout()

This will close STDOUT and reopen it to point at STDERR. The result of this is
that any print statement that does not specify a fielhandle will print to
STDERR instead of STDOUT, in addition any print directly to STDOUT will instead
go to STDERR. A filehandle to the real STDOUT is returned for you to use when
you actually want to write to STDOUT.

This is used by some yath processes that need to print structured data to
STDOUT without letting any third part modules they may load write to the real
STDOUT.

=item $path_to_script = find_yath()

This will attempt to find the C<yath> command line script. When possible this
will return the path that was used to launch yath. If yath was not run to start
the process it will search the paths specified in the L<Config> module. This
will throw an exception if the script cannot be found.

Note: The result is cached so that subsequent calls will return the same path
even if something installs a new yath script in another location that would
otherwise be found first. This guarentees that a single process will not switch
scripts.

=item $path = share_file($relative_file)

Resolve a file inside the distribution's C<share/> directory. In a development
checkout this prefers the in-repo C<share/> directory; otherwise it falls back
to L<File::ShareDir/dist_file> for the C<Test2-Harness2> distribution.

=item $path = share_dir($relative_dir)

Resolve a directory inside the distribution's C<share/> directory. In a
development checkout this prefers the in-repo C<share/> directory; otherwise it
falls back to L<File::ShareDir/dist_dir> for the C<Test2-Harness2>
distribution.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

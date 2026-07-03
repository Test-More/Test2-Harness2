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
    find_runner_links
    is_generated_test_pl
    find_yath
    share_dir
    changes_applicable
};

# Whether changed-files finder/coverage options apply to the current command.
# They do not apply to the projects command (which orchestrates other commands
# rather than running tests itself). Shared by Options::Finder and Plugin::Cover.
sub changes_applicable {
    my ($opt, $options, $settings) = @_;
    return 1 unless $settings && $settings->check_group('harness') && $settings->harness->check_option('command');
    my $cmd = $settings->harness->command;
    return 0 if $cmd && $cmd->isa('App::Yath2::Command::projects');
    return 1;
}

# The fixed suffix every discovery symlink basename ends with (the project /
# host / user prefixes vary, but this trailer is constant -- see find_runner_link).
# Used by find_runner_links to enumerate ALL candidate symlinks in a directory.
our $RUNNER_LINK_SUFFIX = 'yath-runner.sock';

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

# Find the discovery symlink named $name by walking the directory tree upward from
# the cwd and testing -l on $dir/$name at each level, returning the FIRST link path
# found (the link itself, not its target -- realpath would resolve the symlink to its
# socket target and so could never match). Shares the cwd-to-root walk with
# _glob_runner_links_updir via _walk_updirs.
sub _find_link_in_updir {
    my ($name) = @_;

    my @links = _walk_updirs(sub {
        my ($dir) = @_;
        my $link = File::Spec->catfile($dir, $name);
        return -l $link ? ($link) : ();
    });

    return $links[0];
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

# Enumerate EVERY candidate discovery symlink reachable under the same dir/name
# rules find_runner_link uses for the single-link lookup, so `yath list` can find
# all persistent runners (not just the one for the current project). Returns a
# de-duplicated list of absolute symlink paths (live or dangling -- liveness is a
# socket connect, done in App::Yath2::Discovery, not here).
#
# The rules mirror find_runner_link exactly:
#   * an explicit --pfile (persist_file) names a single link -- return just it;
#   * otherwise the search directory is --persist-dir / $YATH_PERSISTENCE_DIR /
#     the system temp dir, and we glob that dir for every `.*-${SUFFIX}` symlink
#     (all users/hosts/projects that published there);
#   * additionally, when no dir was forced and the cwd is writable (the cwd-walk
#     case find_runner_link falls back to), walk the directory tree upward and
#     collect any matching symlink at each level (a project that published into
#     its own checkout root rather than the temp dir).
sub find_runner_links {
    my ($settings, %params) = @_;

    croak "Settings is a required argument" unless $settings;

    my $yath = $settings->harness;

    my %seen;
    my @links;

    my $set_dir = $yath->persist_dir // $ENV{YATH_PERSISTENCE_DIR};
    my $dir     = $set_dir // $ENV{TMPDIR} // $ENV{TEMPDIR} // File::Spec->tmpdir;

    # Glob the search directory for every published discovery symlink. NOTE: we
    # cannot collapse to persist_file the way the single-runner find_runner_link
    # does -- the PreCommand post-process VIVIFIES persist_file to a single
    # candidate path for every command (App::Yath2::Options::PreCommand), so a set
    # persist_file is NOT a reliable "user named one specific link" signal here.
    # Instead we always enumerate the directory and ALSO fold in persist_file when
    # it exists (covering both an explicit --pfile pointing outside this dir and a
    # vivified-but-real path), de-duplicated.
    for my $link (_glob_runner_links($dir)) {
        next if $seen{$link}++;
        push @links => $link;
    }

    # The cwd-walk fallback (find_runner_link uses _find_link_in_updir when no dir
    # is forced and the cwd is writable): a runner may have published into a
    # project checkout root rather than the shared temp dir. Collect those too.
    unless ($set_dir) {
        for my $link (_glob_runner_links_updir()) {
            next if $seen{$link}++;
            push @links => $link;
        }
    }

    # Fold in persist_file when it names a real (live or dangling) symlink -- an
    # explicit --pfile, or a vivified default that happens to exist.
    if (my $pf = $yath->persist_file) {
        push @links => $pf if !$seen{$pf}++ && _runner_link_existsp($pf);
    }

    return @links;
}

# Glob one directory for every discovery symlink ($dir/.*-${SUFFIX}) and return the
# absolute link paths (the link itself, NOT its target -- see _abs_link_path). A
# directory we cannot read (EACCES, missing) yields nothing rather than dying:
# enumeration must be tolerant of other users' unreadable dirs.
sub _glob_runner_links {
    my ($dir) = @_;

    my $abs_dir = eval { realpath(File::Spec->rel2abs($dir)) } // return;
    return unless -d $abs_dir;

    # Every discovery symlink basename is a dotfile ending in the fixed trailer:
    # `.yath-runner.sock` or `.{user}-{host}-{project}-yath-runner.sock` (see
    # find_runner_link's @names construction). Match exactly that shape.
    opendir(my $dh, $abs_dir) or return;
    my @names = grep { $_ =~ m/^\..*\Q$RUNNER_LINK_SUFFIX\E$/ } readdir($dh);
    closedir($dh);

    my @links;
    for my $name (@names) {
        # The dir is already realpath'd; append the basename WITHOUT resolving it
        # (clean_path/realpath on the symlink itself would follow it to its target,
        # the socket -- the caller needs the link path, not the socket; same gotcha
        # _abs_link_path documents).
        my $link = File::Spec->catfile($abs_dir, $name);
        # Match find_runner_link's "present" test: a live OR dangling symlink both
        # count (a dangling one is a crashed runner the caller may want to clean).
        push @links => $link if _runner_link_existsp($link);
    }

    return @links;
}

# The cwd-walk leg: walk from the cwd up to the filesystem root and collect every
# discovery symlink found at each level (the _find_link_in_updir shape, but
# globbing all matching names at each level instead of stopping at the first).
sub _glob_runner_links_updir {
    return _walk_updirs(sub {
        my ($dir) = @_;
        return _glob_runner_links($dir);
    });
}

# Walk from the cwd up to the filesystem root, invoking $per_dir_cb->($dir) at each
# level with the realpath'd DIRECTORY (never a realpath'd leaf path -- callers build
# and test the leaf themselves, because realpath on a discovery symlink would follow
# it to its socket target; see _abs_link_path). The %seen guard and the parent==dir
# check terminate the walk at cycles / the root. Each callback's returned list is
# collected in walk order (cwd first, then parents) and the full list is returned; a
# find-first caller just takes [0].
sub _walk_updirs {
    my ($per_dir_cb) = @_;

    my $dir = eval { realpath(File::Spec->rel2abs('.')) } or return;

    my (%seen, @out);
    while (defined $dir && length $dir && !$seen{$dir}++) {
        push @out => $per_dir_cb->($dir);

        my $parent = realpath(File::Spec->catdir($dir, '..')) // last;
        last if $parent eq $dir;    # reached the filesystem root
        $dir = $parent;
    }

    return @out;
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
        is_generated_test_pl
        find_yath
        share_dir
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

=item @paths = find_runner_links($settings, %params)

Enumerate B<every> candidate discovery symlink reachable under the same
directory/name rules L</find_runner_link> uses, so a command can find B<all>
persistent runners rather than just the one for the current project. Returns a
de-duplicated list of absolute symlink paths.

The search directory is C<--persist-dir> / C<$YATH_PERSISTENCE_DIR> / the system
temp dir, globbed for every C<.*-yath-runner.sock> symlink (all
users/hosts/projects that published there); when no directory was forced, the
cwd-walk fallback (a runner that published into a project checkout root) is also
scanned upward. A C<persist_file> (C<--pfile>) that names a real symlink is folded
in too -- but it does B<not> collapse the search to a single link, because the
C<PreCommand> post-process vivifies C<persist_file> for every command, so a set
value is not a reliable "the user named one link" signal here.

Both live and dangling symlinks are returned; liveness is a socket connect, done by
L<App::Yath2::Discovery/list>. A directory that cannot be read (another user's
unreadable temp area) is skipped silently rather than throwing.

=item $bool = is_generated_test_pl($path_to_test_file)

Check if the specified test file was generated by the C<yath init> command.

=item $path_to_script = find_yath()

This will attempt to find the C<yath> command line script. When possible this
will return the path that was used to launch yath. If yath was not run to start
the process it will search the paths specified in the L<Config> module. This
will throw an exception if the script cannot be found.

Note: The result is cached so that subsequent calls will return the same path
even if something installs a new yath script in another location that would
otherwise be found first. This guarentees that a single process will not switch
scripts.

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

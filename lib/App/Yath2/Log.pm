package App::Yath2::Log;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Cwd ();
use Fcntl qw/SEEK_SET SEEK_END/;
use File::Spec ();
use Time::HiRes ();

# Dispatcher class for the new_log_refactor reader API. This class is
# NOT a base class: it has no instance state of its own. It exists to
# pick the right backend class given the constructor's argument shape
# and return a fresh instance of that class.
#
# Backend selection by argument shape:
#
#   App::Yath2::Log->new(live => $dir)  # Live workdir (still being written)
#   App::Yath2::Log->new(dir  => $dir)  # Sealed / extracted directory
#   App::Yath2::Log->new(file => $f)    # *.yath archive: tar.zidx or sqlite
#                                       # (auto-detect by magic bytes)
#   App::Yath2::Log->new(dbh  => ..., uuid => ...)
#   App::Yath2::Log->new(dsn  => ..., user => ..., pass => ...,
#                        attrs => ..., uuid => ...)
#
# The dispatcher delegates by loading the appropriate backend class
# and returning the new instance directly. It performs no work other
# than detection.
#
# In addition to ->new the class also offers a few legacy helpers
# (->open, ->find_latest, ->update_last_log_symlink) that drive
# integration with the rest of the codebase.

sub new {
    my ($class, %args) = @_;

    # Live directory backend.
    if (defined $args{live}) {
        croak "live + dir / file / dbh / dsn are mutually exclusive"
            if defined $args{dir} || defined $args{file} || defined $args{dbh} || defined $args{dsn};

        require App::Yath2::Log::Live;
        return App::Yath2::Log::Live->new(path => delete $args{live}, %args);
    }

    # Sealed directory backend.
    if (defined $args{dir}) {
        croak "dir + file / dbh / dsn are mutually exclusive"
            if defined $args{file} || defined $args{dbh} || defined $args{dsn};

        require App::Yath2::Log::Directory;
        return App::Yath2::Log::Directory->new(path => delete $args{dir}, live => 0, %args);
    }

    # Single file backend; auto-detect tar.zidx vs sqlite via magic.
    if (defined $args{file}) {
        croak "file + dbh / dsn are mutually exclusive"
            if defined $args{dbh} || defined $args{dsn};

        my $path = delete $args{file};
        croak "file '$path' does not exist" unless -e $path;
        croak "file '$path' is a directory; use dir => or live => instead"
            if -d $path;

        my $kind = $class->_detect_file_kind($path);
        if ($kind eq 'sqlite') {
            require App::Yath2::Log::Sqlite;
            return App::Yath2::Log::Sqlite->new(file => $path, %args);
        }
        if ($kind eq 'tar.zidx') {
            require App::Yath2::Log::TarZIdx;
            return App::Yath2::Log::TarZIdx->new(path => $path, %args);
        }

        croak "Unable to identify '$path' as a yath log archive (not sqlite or tar.zidx)";
    }

    # Database connection forms.
    if (defined $args{dbh} || defined $args{dsn}) {
        require App::Yath2::Log::Sqlite;
        return App::Yath2::Log::Sqlite->new(%args);
    }

    croak "App::Yath2::Log->new requires one of: live, dir, file, dbh, dsn";
}

# Detect the on-disk kind of a $path. Returns 'sqlite', 'tar.zidx', or
# 'unknown'. The check is best-effort: SQLite databases start with the
# 16-byte 'SQLite format 3\0' header; tar.zidx archives end with the
# 32-byte footer beginning 'YZIDXv1\0'. We sniff both.
sub _detect_file_kind {
    my ($class, $path) = @_;

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;

    my $head;
    read($fh, $head, 16);
    if (defined $head && length($head) == 16 && $head eq "SQLite format 3\0") {
        close $fh;
        return 'sqlite';
    }

    my $size = -s $path;
    if (defined $size && $size >= 32) {
        seek($fh, $size - 32, SEEK_SET);
        my $foot;
        read($fh, $foot, 32);
        if (defined $foot && length($foot) == 32 && substr($foot, 0, 8) eq "YZIDXv1\0") {
            close $fh;
            return 'tar.zidx';
        }
    }

    close $fh;
    return 'unknown';
}

# Shape of the in-cwd symlink that always points at the most recent
# archive a `yath test` run produced from this working directory.
# Consumers (yath replay, yath extract, yath failed, ...) honour it
# when no explicit log path was given on the command line.
use constant LAST_LOG_SYMLINK => 'last_log.yath';

# Locate the most recent log archive for the current cwd.
#
#   1. ./last_log.yath -- if present, the symlink target wins.
#   2. Glob ${TMPDIR}/${project}-${user}-*.yath. Sort by stamp embedded
#      in the filename; ties (same-second runs) are broken by hi-res
#      mtime.
#
# Returns the absolute path of the winning archive, or undef when
# nothing matches.
sub find_latest {
    my ($class, $settings) = @_;
    croak "settings is required" unless defined $settings;

    my $cwd = $settings->yath->cwd // Cwd::getcwd();

    my $sym = File::Spec->catfile($cwd, LAST_LOG_SYMLINK);
    if (-l $sym || -e $sym) {
        return $sym;
    }

    my $project = $settings->yath->project;
    my $user    = $settings->yath->user;
    return undef unless defined $project && length $project;
    return undef unless defined $user    && length $user;

    return undef if $project eq '__UNKNOWN__';

    # The original system tmpdir captured by App::Yath::Script
    # before yath swapped TMPDIR for its per-invocation workdir.
    # File::Spec->tmpdir() in this process returns the workdir
    # tmp; the archives live in the original system tmp.
    my $tmp     = $settings->yath->orig_tmp // File::Spec->tmpdir();
    my $pattern = File::Spec->catfile($tmp, "${project}-${user}-*.yath");

    my @hits;
    for my $path (glob $pattern) {
        next unless -f $path;
        my ($name) = File::Spec->splitpath($path) ? (File::Spec->splitpath($path))[2] : $path;
        my ($stamp) = $name =~ m{-(\d{8}-\d{6})-\d+\.yath\z}
            or next;
        my $mtime = (Time::HiRes::stat($path))[9] // 0;
        push @hits => [$stamp, $mtime, $path];
    }
    return undef unless @hits;

    @hits = sort { $b->[0] cmp $a->[0] || $b->[1] <=> $a->[1] } @hits;
    return $hits[0][2];
}

# Update (or create) the ./last_log.yath symlink in the given
# directory so it points at $archive_path. Replaces any existing
# symlink atomically; refuses to overwrite a regular file at the
# target path so the user does not lose data through a stale name
# clash.
sub update_last_log_symlink {
    my ($class, $archive_path, %p) = @_;
    croak "archive_path is required" unless defined $archive_path && length $archive_path;

    my $cwd = $p{cwd} // Cwd::getcwd();
    my $sym = File::Spec->catfile($cwd, LAST_LOG_SYMLINK);

    if (-e $sym && !-l $sym) {
        warn "refusing to replace non-symlink '$sym' with last_log.yath\n";
        return;
    }

    unlink $sym if -l $sym;
    symlink($archive_path, $sym)
        or warn "could not create symlink '$sym' -> '$archive_path': $!\n";

    return $sym;
}

# Legacy entry point kept so existing CLI commands and integration
# tests can still call ->open(path => ...). Internally this just
# auto-detects file vs directory and forwards to ->new.
sub open {
    my ($class, %args) = @_;

    my $file = delete $args{file};
    my $dir  = delete $args{dir};
    my $path = delete $args{path};

    croak "Pass exactly one of 'file', 'dir', or 'path'"
        if 1 != grep { defined($_) } $file, $dir, $path;

    if (defined $path) {
        croak "path '$path' does not exist" unless -e $path;
        if (-d $path) {
            $dir = $path;
        }
        else {
            $file = $path;
        }
    }

    if (defined $dir) {
        # ->open historically auto-detected live vs sealed; the new
        # API is explicit, so we route this to the sealed Directory
        # backend by default. Callers that want live should call
        # ->new(live => $dir) explicitly.
        return $class->new(dir => $dir, %args);
    }

    return $class->new(file => $file, %args);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log - Dispatcher for the yath log reader API.

=head1 SYNOPSIS

    use App::Yath2::Log;

    my $log = App::Yath2::Log->new(live => $logs_dir);    # live workdir
    my $log = App::Yath2::Log->new(dir  => $logs_dir);    # sealed dir
    my $log = App::Yath2::Log->new(file => $yath_file);   # tar.zidx or sqlite
    my $log = App::Yath2::Log->new(dbh  => $dbh, uuid => $u);
    my $log = App::Yath2::Log->new(dsn  => $dsn, user => $u, pass => $p,
                                   attrs => \%a, uuid => $u);

    while (my $event = $log->event($timeout)) {
        ...;
        last if $log->EOE;
    }

    my $events = $log->artifacts($run_id, $job_id, $job_try)->events;

=head1 DESCRIPTION

Dispatcher that picks the appropriate backend (Live / Directory /
TarZIdx / Sqlite) given the constructor arguments. The dispatcher
itself holds no state -- it simply loads and constructs the backend.

The backend implements the Log reader API described in
F<LOGGER_ARTIFACT_REFACTOR2>: listing methods (services / runs / jobs
/ tries / has_* / last_try), the artifacts() handle factory, and the
depth-first event() iterator that walks
C<services/harness/events.jsonl.zst> down through nested
C<harness_collector_start> events.

=head1 SEE ALSO

L<App::Yath2::Log::Live>, L<App::Yath2::Log::Directory>,
L<App::Yath2::Log::TarZIdx>, L<App::Yath2::Log::Sqlite>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

package App::Yath2::Log;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use Cwd ();
use Fcntl qw/SEEK_SET SEEK_END/;
use File::Basename qw/basename/;
use File::Spec ();
use POSIX ();
use Sys::Hostname ();
use Time::HiRes ();

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/encode_json/;

# Dispatcher class for the Log reader API. This class is NOT a base
# class: it has no instance state of its own. It exists to pick the
# right backend class given the constructor's argument shape and
# return a fresh instance of that class.
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

    # Auto-detect backend from a single filesystem path: directory
    # routes to Directory backend; regular file gets type detection
    # by magic bytes (tar.zidx vs sqlite). Provided so callers that
    # accept "an arbitrary log path" don't have to dispatch on
    # -d/-f themselves.
    if (defined $args{auto}) {
        croak "auto + live / dir / file / dbh / dsn are mutually exclusive"
            if defined $args{live} || defined $args{dir} || defined $args{file}
            || defined $args{dbh}  || defined $args{dsn};

        my $path = delete $args{auto};
        croak "auto path must be non-empty" unless length $path;
        croak "auto path '$path' does not exist" unless -e $path;
        if (-d $path) {
            return $class->new(dir => $path, %args);
        }
        if (-f $path) {
            return $class->new(file => $path, %args);
        }
        croak "auto path '$path' is not a regular file or directory";
    }

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
            require App::Yath2::DB;
            require App::Yath2::Log::DB;
            my $backend = delete $args{backend} // 'internal';
            my $db = App::Yath2::DB->open(file => $path, backend => $backend);

            # Single-archive sqlite shorthand: pick the singleton archive
            # when uuid not given; throw on multi-archive ambiguity.
            my $uuid = delete $args{uuid};
            unless (defined $uuid) {
                my @uuids = $db->archives;
                croak "no archives in this sqlite log" if @uuids == 0;
                croak "ambiguous; specify uuid => ... (this DB holds " . scalar(@uuids) . " archives)"
                    if @uuids > 1;
                $uuid = $uuids[0];
            }
            return App::Yath2::Log::DB->new(backend => $db, uuid => $uuid);
        }
        if ($kind eq 'tar.zidx') {
            require App::Yath2::Log::TarZIdx;
            return App::Yath2::Log::TarZIdx->new(path => $path, %args);
        }

        croak "Unable to identify '$path' as a yath log archive (not sqlite or tar.zidx)";
    }

    # Database connection forms.
    if (defined $args{dbh} || defined $args{dsn}) {
        require App::Yath2::DB;
        require App::Yath2::Log::DB;
        my $uuid = delete $args{uuid};
        my $db = App::Yath2::DB->open(%args);
        unless (defined $uuid) {
            my @uuids = $db->archives;
            croak "no archives in this DB" if @uuids == 0;
            croak "ambiguous; specify uuid => ... (this DB holds " . scalar(@uuids) . " archives)"
                if @uuids > 1;
            $uuid = $uuids[0];
        }
        return App::Yath2::Log::DB->new(backend => $db, uuid => $uuid);
    }

    croak "App::Yath2::Log->new requires one of: live, dir, file, dbh, dsn";
}

sub META_FORMAT_VERSION { 1 }
sub META_FILENAME       { 'meta.json' }

# Canonical meta.json keys promoted to archives table columns. Anything
# else lands in archives.meta_extras (JSON catch-all). archive_uuid is
# included even though it is its own column -- listing it here keeps
# meta_extras free of the duplicate. format_version is intentionally NOT
# promoted; it round-trips through meta_extras.
sub META_PROMOTED_KEYS {
    qw(archive_uuid created_at host user git_sha project yath_version)
}

# Earliest archive_version this dist can read. Bump manually when making
# breaking schema or producer-side changes -- the read path refuses
# archives whose archive_version is lower than this. There is no
# auto-migration: an older archive must be re-archived (or read with an
# older yath) to be consumed.
sub last_breaking_version { '2.000012' }

# Build the meta.json content for a sealed archive. Returns a hashref
# with the canonical fields. Fields:
#
#   format_version  -- META_FORMAT_VERSION (currently 1)
#   archive_uuid    -- a fresh UUID (or the caller-supplied one)
#   created_at      -- ISO-8601 UTC timestamp
#   host            -- hostname
#   user            -- $ENV{USER} or getpwuid($<)
#   git_sha         -- `git rev-parse HEAD` if cwd is in a git repo,
#                      else undef
#   project         -- basename of cwd, or undef
#   yath_version    -- $App::Yath2::Log::VERSION (per the canonical
#                      version set across the dist)
#
# Live dirs do NOT get meta.json -- only sealed forms do. Callers
# (Directory->archive, DB->insert, etc.) plumb this in explicitly at
# seal time.
sub build_archive_meta {
    my ($class, %p) = @_;

    my $uuid = $p{archive_uuid} // gen_uuid();
    my $cwd  = $p{cwd} // Cwd::getcwd();

    my $now = Time::HiRes::time();
    my @gm  = gmtime(int $now);
    my $stamp = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $gm[5] + 1900, $gm[4] + 1, $gm[3], $gm[2], $gm[1], $gm[0]);

    my $host = eval { Sys::Hostname::hostname() } // 'unknown';
    my $user = $ENV{USER}
        // $ENV{USERNAME}
        // (eval { (getpwuid($<))[0] } || undef);

    my $project;
    {
        my $base = basename($cwd);
        $project = (defined $base && length $base && $base ne '/')
            ? $base
            : undef;
    }

    my $git_sha = _git_sha_for($cwd);

    return {
        format_version => META_FORMAT_VERSION,
        archive_uuid   => $uuid,
        created_at     => $stamp,
        host           => $host,
        user           => $user,
        git_sha        => $git_sha,
        project        => $project,
        yath_version   => $App::Yath2::Log::VERSION,
    };
}

# Resolve git HEAD SHA for $cwd. Best effort: returns undef on any
# kind of failure (not a git repo, no git binary, etc.).
sub _git_sha_for {
    my ($cwd) = @_;
    return undef unless defined $cwd && length $cwd && -d $cwd;

    # Look for a .git in $cwd or any ancestor; bail when we hit FS root
    # without finding one. This keeps us from shelling out to git in
    # workdirs that are not git repos.
    my $probe = $cwd;
    my $found;
    for (1 .. 50) {
        if (-e File::Spec->catfile($probe, '.git')) {
            $found = 1;
            last;
        }
        my $up = File::Spec->catpath((File::Spec->splitpath($probe))[0,1]);
        $up = (File::Spec->splitdir($probe))[-1] eq '' ? $probe : do {
            my @parts = File::Spec->splitdir($probe);
            pop @parts;
            File::Spec->catdir(@parts);
        };
        last if $up eq $probe;
        $probe = $up;
    }
    return undef unless $found;

    # Use `--no-pager` defensively; capture stdout, ignore stderr; use
    # `-C $cwd` to avoid chdir round-trips.
    my $sha;
    my $ok = eval {
        local $SIG{__WARN__} = sub { };
        my $cmd = qq{git --no-pager -C "$cwd" rev-parse HEAD 2>/dev/null};
        my $out = `$cmd`;
        chomp $out if defined $out;
        if (defined $out && $out =~ /^[0-9a-fA-F]{7,}$/) {
            $sha = $out;
        }
        1;
    };
    return $sha;
}

# Encode a meta hashref to UTF-8 JSON bytes.
sub encode_archive_meta {
    my ($class, $meta) = @_;
    return encode_json($meta);
}

# Detect the on-disk kind of a $path. Returns 'sqlite', 'tar.zidx', or
# 'unknown'. The check is best-effort: SQLite databases start with the
# 16-byte 'SQLite format 3\0' header; sealed yath archives (tar.zidx
# and SQL-sealed) end with the 64-byte YATHFOOT trailer carrying a
# 4-byte format_id. We sniff both.
sub _detect_file_kind {
    my ($class, $path) = @_;

    require App::Yath2::Log::Footer;

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;

    my $head;
    read($fh, $head, 16);
    if (defined $head && length($head) == 16 && $head eq "SQLite format 3\0") {
        close $fh;
        return 'sqlite';
    }

    my $size = -s $path;
    my $footer_size = App::Yath2::Log::Footer::FOOTER_SIZE();
    if (defined $size && $size >= $footer_size) {
        seek($fh, $size - $footer_size, SEEK_SET);
        my $tail;
        read($fh, $tail, $footer_size);
        if (defined $tail && length($tail) == $footer_size) {
            my $info = App::Yath2::Log::Footer::unpack_footer($tail);
            if ($info) {
                close $fh;
                my $fid = $info->{format_id};
                return 'tar.zidx' if $fid eq App::Yath2::Log::Footer::FORMAT_ID_TAR();
                return 'sqlite'   if $fid eq App::Yath2::Log::Footer::FORMAT_ID_SQL();
                return 'unknown';
            }
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

    # Construction shapes.
    my $log = App::Yath2::Log->new(live => $logs_dir);     # live workdir
    my $log = App::Yath2::Log->new(dir  => $logs_dir);     # sealed dir
    my $log = App::Yath2::Log->new(file => $yath_file);    # *.yath (auto-detect)
    my $log = App::Yath2::Log->new(                        # pick DB backend
        file    => $yath_file,
        backend => 'dbic',                                 # default 'internal'
    );
    my $log = App::Yath2::Log->new(dbh  => $dbh, uuid => $u);
    my $log = App::Yath2::Log->new(
        dsn   => $dsn,
        user  => $u,
        pass  => $p,
        attrs => \%a,
        uuid  => $u,
    );

    # Listing.
    my @runs     = $log->runs;
    my @globals  = $log->services;             # services not scoped to a run
    my @services = $log->services($run_id);    # services scoped to $run_id
    my @jobs     = $log->jobs($run_id);
    my @tries    = $log->tries($run_id, $job_id);
    my $last     = $log->last_try($run_id, $job_id);

    # Artifacts handle factory (positional forms).
    my $root = $log->artifacts;                     # archive root
    my $svc  = $log->artifacts('harness');          # global service
    my $run  = $log->artifacts(1);                  # run by ord
    my $rsvc = $log->artifacts(1, 'preload-perl');  # run-scoped service
    my $job  = $log->artifacts(1, 1);               # highest try of job
    my $try  = $log->artifacts(1, 1, 1);            # specific try

    # Hashref form is also accepted:
    my $a = $log->artifacts({
        run_id  => 1,
        job_id  => 1,
        job_try => 1,
    });

    # Per-artifact API.
    my $events_bytes = $a->events;       # decompressed bytes
    my $events_zst   = $a->events_zst;   # compressed bytes
    my $events_iter  = $a->events_iter;  # streaming iterator
    while (defined(my $rec = $events_iter->next)) { ... }
    my $spec_iter   = $a->spec_iter;
    my $report_iter = $a->report_iter;
    my @atts        = $a->attachments;
    my $bytes       = $a->attachment('foo.txt');
    my $exists      = $a->exists('foo.txt');
    $a->save('meta.json', $json_bytes);

    # Whole-log depth-first event iterator.
    while (my $event = $log->event($timeout)) {
        ...;
        last if $log->EOE;
    }
    $log->reset;

    # Format conversion / extraction.
    $log->extract($dest_dir);                       # decompress on the way out
    $log->extract($dest_dir, compressed => 1);      # preserve .zst suffixes
    $log->archive($out_path);                       # default tar.zidx
    $log->archive($out_path, format => 'sqlite');
    $log->archive($out_path, runs => [0]);          # scoped extract
    my $aid = $sqlite->insert($source_log);         # multi-archive insert

=head1 DESCRIPTION

Dispatcher that picks the appropriate backend given the
constructor arguments. The dispatcher itself holds no state -- it
loads and constructs the backend, then returns the backend
instance.

Backends:

=over 4

=item L<App::Yath2::Log::Live>

Live workdir while a harness is still writing. Iterators wait for
new bytes; EOE blocks on a still-running harness. Used by the
test command's renderer child.

=item L<App::Yath2::Log::Directory>

Sealed (post-extract or otherwise idle) directory tree. Iterators
treat EOF as end-of-stream. The default for filesystem-shaped
inputs.

=item L<App::Yath2::Log::TarZIdx>

A tar.zidx archive (USTAR + per-file zstd + a trailing index for
random-access reads). Read-only; archive() and insert() construct
new archives.

=item L<App::Yath2::Log::DB>

A thin proxy that wraps any backend doing
L<App::Yath2::Role::DB::Backend>. Construct backends via
L<App::Yath2::DB>; the proxy delegates the archive-shaped surface
to the chosen backend (raw SQL via
L<App::Yath2::DB::Internal>, or DBIx::Class via
L<App::Yath2::DB::DBIC>). All DB shapes are multi-archive: a
"single sqlite .yath file" is just the N=1 case in the same
C<archives> table.

=back

The backend implements the full Log reader API documented in
SYNOPSIS plus per-backend behavior notes:

=over 4

=item *

Live + Directory expose paths under the underlying tree;
C<absolute_path()> is meaningful and C<save()> writes plain files.

=item *

TarZIdx is read-only after construction; C<absolute_path()> throws
because there is no on-disk file per artifact, just an offset into
the archive.

=item *

DB backends keep one row per artifact and translate the on-disk
relative paths spoken by the C<Artifact> handle into
(scope_kind, scope_id, artifact_kind, format, name) tuples. Save
auto-vivifies the necessary scope rows.

=item *

Magic-byte detection picks tar.zidx vs sqlite for C<file =E<gt> $f>:
SQLite magic (16-byte header C<'SQLite format 3\0'>) wins first;
tar.zidx is identified by the 32-byte trailing footer beginning
C<'YZIDXv1\0'>. Anything else fails the constructor.

=back

=head1 LEGACY HELPERS

=over 4

=item App::Yath2::Log->open(file => $f | dir => $d | path => $p)

Auto-detects file vs directory and dispatches to C<new>. The path
form is convenient when the caller does not yet know whether they
have a file or a directory.

=item $path = App::Yath2::Log->find_latest($settings)

Locates the most recent archive for the current cwd: honours
F<./last_log.yath> first, then falls back to the timestamped
glob in C<TMPDIR>.

=item App::Yath2::Log->update_last_log_symlink($archive_path)

Updates F<./last_log.yath> atomically. Refuses to overwrite a
non-symlink at the target path.

=back

=head1 MULTI-ARCHIVE DBs

C<< App::Yath2::Log->new(file => $path) >> targets a single archive:
when a SQLite C<.yath> file holds more than one archive, the
constructor throws "ambiguous; specify uuid => ..." so the caller
must pick one explicitly.

The C<file => ...> form also accepts a C<< backend => 'internal' | 'dbic' >>
selector, defaulting to C<'internal'>. This is the same backend
selector L<App::Yath2::DB/open> takes; it picks which DB-access
implementation services the read path. Production callers that
do not care can omit it.

For workflows that explicitly want to enumerate archives in a
multi-archive DB (server-shaped DBs, multi-archive sqlite files),
use L<App::Yath2::DB>:

    my $db = App::Yath2::DB->open(file => $multi_yath);
    for my $uuid ($db->archives) {
        my $log = App::Yath2::Log::DB->new(backend => $db, uuid => $uuid);
        ...;
    }

The backend shares its DBI handle across the per-archive proxy
objects so opening many archives does not reconnect.

=head1 SEE ALSO

L<App::Yath2::Log::Live>, L<App::Yath2::Log::Directory>,
L<App::Yath2::Log::TarZIdx>, L<App::Yath2::Log::DB>,
L<App::Yath2::DB>, L<App::Yath2::Log::Artifact>,
L<App::Yath2::Log::Iterator::JSONL>,
L<Test2::Harness2::LogLayout>, L<App::Yath2::Command::inspect>.

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

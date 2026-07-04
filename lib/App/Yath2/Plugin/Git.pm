package App::Yath2::Plugin::Git;
use v5.38;

our $VERSION = '2.000000';

use IPC::Cmd qw/can_run/;
use Capture::Tiny qw/capture/;
use parent 'App::Yath2::Plugin';

use Getopt::Yath;

option_group {group => 'git', prefix => 'git', category => "Git Options"} => sub {
    option change_base => (
        type => 'Scalar',
        description => "Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.",
        long_examples  => [" master", " HEAD^", " df22abe4"],
    );
};

my $GIT_CMD = can_run('git');
sub git_cmd { $ENV{GIT_COMMAND} || $GIT_CMD }

sub git_output ($class, @args) {
    my $cmd = $class->git_cmd or return sub {()};

    # Capture::Tiny buffers both streams to temp handles, so a git command that
    # writes more than a pipe's worth of stderr can never deadlock the parent
    # (the old hand-rolled pipe pair drained stderr only after stdout EOF).
    my ($stdout, $stderr, $exit) = capture { system($cmd, @args) };

    # Lenient, non-dying contract: inject_run_data calls this on every run, even
    # in non-git dirs, so only surface stderr when the command actually failed.
    print STDERR $stderr if $exit && defined $stderr && length $stderr;

    # split /^/m keeps the trailing newline on each line, matching the old
    # <$rh> readlines that callers chomp downstream.
    my @lines = length($stdout // '') ? split(/^/m, $stdout) : ();
    return sub { shift @lines };
}

sub inject_run_data ($class, %params) {
    my $meta   = $params{meta};
    my $fields = $params{fields};

    my $long_sha  = $ENV{GIT_LONG_SHA};
    my $short_sha = $ENV{GIT_SHORT_SHA};
    my $status    = $ENV{GIT_STATUS};
    my $branch    = $ENV{GIT_BRANCH};

        my @sets = (
            [\$long_sha, 'rev-parse', 'HEAD'],
            [\$short_sha, 'rev-parse', '--short', 'HEAD'],
            [\$status, 'status', '-s'],
            [\$branch, 'rev-parse', '--abbrev-ref', 'HEAD'],
        );

        for my $set (@sets) {
            my ($var, @args) = @$set;
            next if $$var; # Already set
            my $output = $class->git_output(@args);

            my @lines;
            while (my $line = $output->()) {
                push @lines => $line;
            }

            chomp($$var = join "\n" => @lines);
        }

    return unless $long_sha;

    $meta->{git}->{sha}    = $long_sha;
    $meta->{git}->{status} = $status if $status;

    if ($branch) {
        $meta->{git}->{branch} = $branch;

        my $short = length($branch) > 20 ? substr($branch, 0, 20) : $branch;

        push @$fields => {name => 'git', details => $short, raw => $branch, data => $meta->{git}};
    }
    else {
        $short_sha ||= substr($long_sha, 0, 16);
        push @$fields => {name => 'git', details => $short_sha, raw => $long_sha, data => $meta->{git}};
    }

    return;
}

sub changed_diff ($class, $settings) {
    $class->_changed_diff($settings->git->change_base);
}

sub _changed_diff ($class, $base) {
    my $cmd = $class->git_cmd or return;

    my $from = 'HEAD';

    if ($base) {
        # TODO-107: validate the change base and bound the merge-base walk so a
        # typo'd/nonexistent ref, an orphan/unrelated branch, or a shallow clone
        # (HEAD^..^ past the shallow boundary is a bad revision -> exit 128) can
        # never fork `git merge-base` in an unbounded loop. The old
        #   $from .= "^" while system(... merge-base --is-ancestor $from $base);
        # never inspected $? -- any non-1 exit loops forever spamming git errors.

        # Fail fast (before the loop) if the base does not resolve to a commit.
        {
            my (undef, $stderr, $status) = capture {
                system($cmd => 'rev-parse', '--verify', "${base}^{commit}");
            };
            if ($status) {
                chomp(my $err = $stderr // '');
                die "Invalid --git-change-base '$base': not a resolvable git commit"
                    . ($err ? " ($err)" : '') . "\n";
            }
        }

        # Upper bound on how far HEAD^...^ can walk: the number of commits
        # reachable from HEAD (bounded even in a shallow clone). A belt-and-
        # suspenders guard on top of the per-iteration exit check below.
        my $max   = $class->_commit_count // 0;
        my $steps = 0;

        while (1) {
            my (undef, $stderr, $status) = capture {
                system($cmd => 'merge-base', '--is-ancestor', $from, $base);
            };

            last unless $status;    # exit 0: $from is an ancestor of $base -> done

            # exit 1 == "not an ancestor": keep walking back toward the base.
            # A signal, or any other exit (128 bad revision past a shallow
            # boundary, git missing, ...) is fatal -- looping would just spin
            # 'fatal: bad revision' forever and never start the tests.
            if ((($status & 127) != 0) || (($status >> 8) != 1)) {
                chomp(my $err = $stderr // '');
                die "git merge-base --is-ancestor $from $base failed"
                    . ($err ? ": $err" : sprintf(" (status %d)", $status)) . "\n";
            }

            if ($max && ++$steps > $max) {
                die "Could not find a common ancestor of HEAD and --git-change-base "
                    . "'$base' within $max commit(s); is it on an unrelated branch?\n";
            }

            $from .= "^";
        }

        return $class->_diff_from($from);
    }

    # _diff_from always returns a truthy 2-element (line_sub => ...) list, so we
    # cannot tell "no changes" from the return value. Probe emptiness eagerly:
    # `git diff --quiet HEAD` exits 0 on a clean tree (unless 0 => rewrite to
    # HEAD^ so a clean-tree --changed-only tests the last commit) and 1 on a
    # dirty tree or any error (keep HEAD, the safe default).
    $from = "${from}^" unless system($cmd => 'diff', '--quiet', $from);
    return $class->_diff_from($from);
}

sub _diff_from ($class, $from) {
    my $cmd = $class->git_cmd or return;

    return (line_sub => $class->git_output('diff', '-U1000000', '-W', '--minimal', $from));
}

# Number of commits reachable from HEAD, or undef if git can't answer. Used to
# bound the TODO-107 merge-base walk; bounded even in a shallow clone.
sub _commit_count ($class) {
    my $cmd = $class->git_cmd or return undef;

    my ($stdout, undef, $status) = capture {
        system($cmd => 'rev-list', '--count', 'HEAD');
    };
    return undef if $status;

    chomp(my $n = $stdout // '');
    return undef unless $n =~ /^\d+$/;
    return $n;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Plugin::Git - Plugin to attach git data to a test run.

=head1 DESCRIPTION

This plugin will attach git data to your test logs if any is available.

=head1 SYNOPSIS

    $ yath test -pGit ...

=head1 READING THE DATA

The data is attached to the 'run' entry in the log file. This can be seen
directly in the json data. The data is also easily accessible with
L<Test2::Harness2::UI>.

The data will include the long sha, short sha, branch name, and a brief status.

=head1 PROVIDED OPTIONS

=head3 Git Options

=over 4

=item --git-change-base HEAD^

=item --git-change-base master

=item --git-change-base df22abe4

=item --no-git-change-base

Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.


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

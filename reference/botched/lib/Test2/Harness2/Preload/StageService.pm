package Test2::Harness2::Preload::StageService;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak confess/;
use POSIX qw/:sys_wait_h/;

use Test2::Harness2::Util qw/mod2file/;
use Test2::Harness2::MiniHarness;

use Test2::Harness2::Util::HashBase qw{
    <stage_def
    <parent_pid
    <stage_name
    <_loaded
    <_reloader
};

sub init {
    my $self = shift;

    croak "'stage_def' is a required attribute"
        unless $self->{+STAGE_DEF};

    $self->{+STAGE_NAME} = $self->{+STAGE_DEF}->name;
    $self->{+PARENT_PID} //= $$;
    $self->{+_LOADED}    //= 0;
}

sub load_modules {
    my $self = shift;

    my $stage_def = $self->{+STAGE_DEF};
    my $seq       = $stage_def->load_sequence;

    for my $item (@$seq) {
        if (ref($item) eq 'CODE') {
            my $ok  = eval { $item->(); 1 };
            my $err = $@;
            die "Coderef in load_sequence for stage '$self->{+STAGE_NAME}' failed: $err"
                unless $ok;
        }
        else {
            my $file = mod2file($item);
            my $ok   = eval { require $file; 1 };
            my $err  = $@;
            die "Failed to load module '$item' (file: $file) for stage '$self->{+STAGE_NAME}': $err"
                unless $ok;
        }
    }

    $self->{+_LOADED} = 1;

    return 1;
}

sub launch_test {
    my $self   = shift;
    my %params = @_;

    my $test_file = $params{test_file} or croak "test_file is required";
    my $stage_def = $self->{+STAGE_DEF};

    # Pre-fork callbacks
    $stage_def->do_pre_fork();

    my $pid = fork();
    confess "fork() failed: $!" unless defined $pid;

    if ($pid == 0) {
        # === CHILD PROCESS ===

        # Post-fork callbacks
        my $ok  = eval { $stage_def->do_post_fork(); 1 };
        my $err = $@;
        unless ($ok) {
            warn "post_fork callback failed: $err";
            POSIX::_exit(255);
        }

        # Pre-launch callbacks
        $ok  = eval { $stage_def->do_pre_launch(); 1 };
        $err = $@;
        unless ($ok) {
            warn "pre_launch callback failed: $err";
            POSIX::_exit(255);
        }

        # Run the test via MiniHarness (exec mode — preloaded modules
        # don't survive exec, but the architecture is in place for
        # future goto::file integration).
        $ok = eval {
            my $result = Test2::Harness2::MiniHarness->run(
                test_file => $params{test_file},
                log_dir   => $params{log_dir},
                uuid      => $params{uuid},
                includes  => $params{includes},
                env       => $params{env},
                switches  => $params{switches},
                (defined $params{preloaded} ? (preloaded => $params{preloaded}) : ()),
            );
            POSIX::_exit($result->passed ? 0 : 1);
            1;
        };
        $err = $@;
        warn "MiniHarness->run failed: $err" unless $ok;
        POSIX::_exit(255);
    }

    # === PARENT PROCESS ===
    waitpid($pid, 0);
    my $child_status = $?;
    my $exit_code    = $child_status >> 8;

    return {
        passed    => ($exit_code == 0) ? 1 : 0,
        exit_code => $child_status,
        test_file => $test_file,
        uuid      => $params{uuid},
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preload::StageService - Stage process that loads modules and launches tests.

=head1 DESCRIPTION

A StageService represents a running preload stage process. It loads modules
defined in a L<Test2::Harness2::Preload::Stage> definition and can launch
tests by forking child processes that inherit the preloaded modules in memory.

Currently tests are launched via L<Test2::Harness2::MiniHarness> in exec mode.
A future enhancement will add C<goto::file> support so that forked children
can run tests without exec, preserving preloaded modules in memory.

=head1 SYNOPSIS

    use Test2::Harness2::Preload::StageService;
    use Test2::Harness2::Preload::Stage;

    my $stage_def = Test2::Harness2::Preload::Stage->new(
        name          => 'MyStage',
        load_sequence => ['Some::Module', 'Another::Module'],
    );

    my $service = Test2::Harness2::Preload::StageService->new(
        stage_def => $stage_def,
    );

    $service->load_modules();

    my $result = $service->launch_test(
        test_file => 't/foo.t',
        log_dir   => '/tmp/logs',
        uuid      => 'abc-123',
        includes  => ['lib'],
    );

    print "Passed!\n" if $result->{passed};

=head1 METHODS

=over 4

=item $service->load_modules()

Load all modules in the stage definition's load_sequence.

=item $result = $service->launch_test(%params)

Fork a child and run a test via MiniHarness. Returns a hashref with keys:
C<passed>, C<exit_code>, C<test_file>, C<uuid>.

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

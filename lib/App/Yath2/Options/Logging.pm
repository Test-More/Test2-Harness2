package App::Yath2::Options::Logging;
use strict;
use warnings;

our $VERSION = '2.000011';

use Getopt::Yath;

option_group {group => 'logging', category => 'Logging Options'} => sub {
    option log => (
        type        => 'Bool',
        short       => 'L',
        default     => 0,
        description => 'Turn on user-visible logging. The log archive is written by App::Yath2::LogArchive; --log-file or --log-dir choose the destination.',
    );

    option dir => (
        prefix      => 'log',
        type        => 'Scalar',
        description => 'Write the log archive into this directory using the YYYYMMDD-HHMMSS.yath naming convention. Ignored when --log-file is also set.',
    );

    option file => (
        prefix      => 'log',
        type        => 'Scalar',
        short       => 'F',
        description => 'Write the log archive to this exact path. Wins over --log-dir; the path is used verbatim, no extension is appended.',
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Logging - User-facing log destination options
(--log / -L, --log-dir, --log-file / -F).

=head1 DESCRIPTION

Defines the C<logging> option group consumed by C<yath test> (and
any future command that wants the same destination semantics) to
choose where C<App::Yath2::LogArchive-E<gt>create> writes the run's
archive.

The actual archive write happens in the consuming command; this
module only owns the option parsing and the C<$settings-E<gt>logging>
accessor.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=cut

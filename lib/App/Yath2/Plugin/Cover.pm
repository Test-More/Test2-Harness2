package App::Yath2::Plugin::Cover;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util qw/clean_path mod2file/;
use Test2::Harness2::Util::JSON qw/encode_json stream_json_l/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;

use parent 'App::Yath2::Plugin';
use Test2::Harness2::Util::HashBase qw/-aggregator -no_aggregate +metrics +outfile/;

use Getopt::Yath;

# prefix => 'cover' makes the CLI long forms --cover-NAME (matching the old
# plugin name munging which prepended the group as a prefix). Note: the prefix
# also applies to alts, so alts here are the bare (un-prefixed) spellings.
option_group {group => 'cover', prefix => 'cover', category => "Cover Options"} => sub {
    option types => (
        alt => ['type'],
        type => 'List',
        # List defaults are flattened via add_value, so return a flat list.
        default => sub { ('pl', 'pm') },
    );

    option dirs => (
        alt => ['dir'],
        type => 'List',
        default => sub { ('lib') },

        # Trigger fires before the value is stored; glob-expand each raw
        # value in place so the stored list contains the expanded paths.
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';
            @{$params{val}} = map { glob($_) } @{$params{val}};
        },
    );

    option exclude_private => (
        type => 'Bool',
        default => 0,
        description => "",
    );

    option files => (
        type => 'Bool',
        description => "Use Test2::Plugin::Cover to collect coverage data for what files are touched by what tests. Unlike Devel::Cover this has very little performance impact (About 4% difference)",
    );

    option metrics => (
        type => 'Bool',
        description => '',
    );

    option write => (
        type => 'Auto',
        normalize => \&clean_path,
        long_examples => ['', '=coverage.jsonl', '=coverage.json'],
        description => "Create a json or jsonl file of all coverage data seen during the run (This implies --cover-files).",

        # Bare --cover-write defaults to coverage.jsonl. Autofill bypasses
        # normalize, so clean the path here. The =PATH form goes through
        # normalize (clean_path) above.
        autofill => sub { clean_path("coverage.jsonl") },
    );

    option aggregator => (
        alt => ['agg'],
        type => 'Scalar',
        long_examples => [' ByTest', ' ByRun', ' +Custom::Aggregator'],
        description => 'Choose a custom aggregator subclass',
        normalize => sub ($agg) {
            return $agg if $agg =~ s/^\+//;
            return "Test2::Harness2::Log::CoverageAggregator::$agg";
        },
    );

    option class => (
        type => 'Scalar',
        description => 'Choose a Test2::Plugin::Cover subclass',
        default => 'Test2::Plugin::Cover',
    );

    option manager => (
        type => 'Scalar',
        description => "Coverage 'from' manager to use when coverage data does not provide one",
        long_examples => [ ' My::Coverage::Manager'],
        applicable => \&changes_applicable,
    );

    option from_type => (
        type => 'Scalar',
        description => 'File type for coverage source. Usually it can be detected, but when it cannot be you should specify. "json" is old style single-blob coverage data, "jsonl" is the new by-test style, "log" is a logfile from a previous run.',
        long_examples => [' json', ' jsonl', ' log' ],
    );

    option maybe_from_type => (
        type => 'Scalar',
        'description' => 'Same as "from_type" but for "maybe_from". Defaults to "from_type" if that is specified, otherwise auto-detect',
        long_examples => [' json', ' jsonl', ' log' ],
    );

    option from => (
        type => 'Scalar',
        description => "This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will not be run if the file/url is invalid.",
        long_examples => [' path/to/log.jsonl', ' http://example.com/coverage', ' path/to/coverage.jsonl']
    );

    option maybe_from => (
        type => 'Scalar',
        description => "This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will coninue if even if the coverage file/url is invalid.",
        long_examples => [' path/to/log.jsonl', ' http://example.com/coverage', ' path/to/coverage.jsonl']
    );

    option_post_process 0 => \&post_process;
};

sub changes_applicable ($opt, $options, $settings) {
    return 1 unless $settings && $settings->check_group('harness') && $settings->harness->check_option('command');
    my $c = $settings->harness->command;
    return 0 if $c && $c->isa('App::Yath2::Command::projects');
    return 1;
}

sub spawn_args {
    my $self = shift;
    my ($settings) = @_;

    return () unless $settings->cover->files || $settings->cover->metrics || $settings->cover->write;

    my $class = $settings->cover->class;
    return ('-M' . $class . '=disabled,1');
}

sub post_process ($options, $state) {
    my $settings = $state->{settings};

    my $cover = $settings->cover;

    if ($cover->files || $cover->write || $cover->metrics) {
        my $cover_class = $cover->class // 'Test2::Plugin::Cover';

        my $ok = eval { require(mod2file($cover_class)); 1 };
        my $err = $@;
        die "Could not enable file coverage, could not load '$cover_class': $err" unless $ok;

        # Vivify load_import if nothing was set on the CLI yet, then maintain
        # the insertion-ordered '@' key (per Run.pm dbi_profiling pattern).
        # Guard with check_option first: this post and Run.pm's own post share
        # weight 0, so ordering is not guaranteed and the option may not be
        # registered yet -- reading it unguarded would confess via AUTOLOAD.
        my $run = $settings->run;
        $run->create_option(load_import => {})
            unless $run->check_option('load_import') && defined $run->load_import;
        my $load_import = $run->load_import;
        unless ($load_import->{$cover_class}) {
            push @{$load_import->{'@'}} => $cover_class;
            $load_import->{$cover_class} = [];
        }
    }
}

sub annotate_event {
    my $self = shift;
    return if $self->{+NO_AGGREGATE};
    my ($e, $settings) = @_;

    unless ($self->{+AGGREGATOR}) {
        my $do_cover = $settings->cover->files;
        my $file = $settings->cover->write;
        my $metrics = $settings->cover->metrics;

        unless ($file || $metrics || $do_cover) {
            $self->{+NO_AGGREGATE} = 1;
            return;
        }

        my $agg = $settings->cover->aggregator;
        if (!$agg) {
            if ($file) {
                if ($file =~ m/\.json$/) {
                    $agg = 'Test2::Harness2::Log::CoverageAggregator::ByRun';
                }
                elsif ($file =~ m/\.jsonl$/) {
                    $agg = 'Test2::Harness2::Log::CoverageAggregator::ByTest';
                }
            }
            else {
                $agg = 'Test2::Harness2::Log::CoverageAggregator::ByTest';
            }
        }

        my $encode;
        if ($agg eq 'Test2::Harness2::Log::CoverageAggregator::ByRun') {
            $encode = \&encode_json;
        }
        elsif ($agg eq 'Test2::Harness2::Log::CoverageAggregator::ByTest') {
            $encode = sub { encode_json($_[0]) . "\n" };
        }

        require(mod2file($agg));
        $self->{+AGGREGATOR} = $agg->new(
            $file   ? (file   => $file)   : (),
            $encode ? (encode => $encode) : (),
        );
    }

    my $fd = $e->{facet_data};

    my @out;

    if ($fd->{coverage} || $fd->{harness_job_end} || $fd->{harness_job_start}) {
        if (my $list = $self->{+AGGREGATOR}->process_event($e)) {
            die "Aggregator flushed without a job end!" unless $fd->{harness_job_end};
            die "Aggregator flushed more than 1 job!" unless @$list == 1;
            push @out => (job_coverage => {details => 'Job Coverage', manager => $list->[0]->{manager}, files => $list->[0]->{files}, test => $list->[0]->{test}});
        }
    }

    if ($fd->{harness_final}) {
        my $cover      = $settings->cover;
        my $aggregator = $self->{+AGGREGATOR} or return;
        my $metrics;
        $metrics = $self->metrics($settings) if $cover->metrics;
        my $final = $aggregator->finalize();

        my $percentages = $self->_percentages($metrics);
        my $raw         = join ", ", map { "$_->[0]: $_->[2]/$_->[1] ($_->[3])" } @$percentages;
        my $details     = join ", ", map { "$_->[0] $_->[3]" } @$percentages;

        $details = "coverage metrics" unless length $details;

        push @out => (
            run_fields => [
                {name => 'coverage', details => $details, data => $metrics, $raw ? (raw => $raw) : ()},
            ],
        );

        push @out => (
            run_coverage => {
                details  => 'Run Coverage',
                files    => $final->[0]->{files},
                testmeta => $final->[0]->{testmeta},
            },
        ) if $final && @$final;
    }

    return @out;
}

sub metrics {
    my $self = shift;
    my ($settings) = @_;

    my $cover = $settings->cover;

    return unless $cover->metrics;

    my $aggregator = $self->{+AGGREGATOR};

    return $self->{+METRICS} //= $aggregator->build_metrics(
        dirs            => $cover->dirs,
        types           => $cover->types,
        exclude_private => $cover->exclude_private,
    );
}

sub _percentages {
    my $self = shift;
    my ($metrics) = @_;

    return unless $metrics;

    my @out;

    for my $metric (sort keys %$metrics) {
        next if $metric eq 'untested';
        my $data = $metrics->{$metric} or next;
        my ($total, $tested) = @{$data}{qw/total tested/};
        push @out => [$metric, $total, $tested, $total ? (int(($tested / $total) * 100) . '%') : '100%'];
    }

    return \@out;
}

sub finalize {
    my $self = shift;
    my ($settings) = @_;

    my $cover   = $settings->cover;
    my $file    = $cover->write;
    my $metrics = $cover->metrics;

    return unless $file || $metrics;
    print "\nCoverage:\n";

    my $aggregator = $self->{+AGGREGATOR};

    if ($metrics) {
        my $data = $self->metrics($settings);

        require Term::Table;
        my $table = Term::Table->new(
            header => [qw/METRIC TOTAL TESTED PERCENTAGE/],
            rows   => $self->_percentages($data),
        );
        print map { "$_\n" } $table->render;
    }

    print "Wrote coverage file: $file\n" if $file;

    print "\n";
}

sub _deduce_content_type {
    my ($path, $type) = @_;

    if ($type) {
        if ($type eq 'json') {
            return {
                content_type => 'application/json',
                parser       => 'json',
                format       => $type,
            };
        }
        elsif ($type eq 'jsonl' || $type eq 'log') {
            return {
                content_type => 'application/jsonl',
                parser       => 'jsonl',
                format       => $type,
            };
        }
    }

    if ($path =~ m/\.jsonl/) {
        return {
            content_type => 'application/jsonl',
            parser       => 'jsonl',
            format       => undef,
        };
    }

    if ($path =~ m/\.json/) {
        return {
            content_type => 'application/json',
            parser       => 'json',
            format       => undef,
        };
    }

    return {};
}

sub get_coverage_tests {
    my $self = shift;
    my ($settings, $changes) = @_;

    my $cover = $settings->cover;
    my $from  = $cover->from;
    my $maybe = $cover->maybe_from;

    return unless $from || $maybe;

    if ($maybe) {
        my $type_data = $self->_deduce_content_type($maybe, $cover->maybe_from_type);

        my @out;
        my $ok = eval { @out = $self->_get_coverage_tests($settings, $changes, $maybe, $type_data); 1 };
        my $err = $@;
        return @out if $ok;
        warn "Could not get coverage from '$maybe', continuing anyway... error was: $err";
    }

    return $self->_get_coverage_tests($settings, $changes, $from)
        if $from;

    return;
}

sub _get_coverage_tests {
    my $self = shift;
    my ($settings, $changes, $source, $type_data) = @_;

    my @out;

    stream_json_l(
        $source => sub { push @out => $self->coverage_handler($settings, $changes, $type_data, @_) },
        $type_data->{content_type} ? (http_args => [{headers => {'Content-Type' => $type_data->{content_type}}}]) : (),
    );

    return @out;
}

sub coverage_handler {
    my $self = shift;
    my ($settings, $changes, $type_data, $set, $res) = @_;

    return unless $set;

    my ($agg, $data);
    if (my $fd = $set->{facet_data}) {
        if ($data = $fd->{job_coverage}) {
            require 'Test2/Harness2/Log/CoverageAggregator/ByTest.pm' unless $INC{'Test2/Harness2/Log/CoverageAggregator/ByTest.pm'};
            $agg = 'Test2::Harness2::Log::CoverageAggregator::ByTest';
        }
        elsif($data = $fd->{run_coverage}) {
            require 'Test2/Harness2/Log/CoverageAggregator/ByRun.pm' unless $INC{'Test2/Harness2/Log/CoverageAggregator/ByRun.pm'};
            $agg = 'Test2::Harness2::Log::CoverageAggregator::ByRun';
        }
        else {
            return;
        }
    }
    else {
        $data = $set;
        $agg  = $set->{aggregator} // return;
        my $aggfile = mod2file($agg);
        require($aggfile) unless $INC{$aggfile};
    }

    return $agg->get_coverage_tests($settings, $changes, $data);
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Plugin::Cover - Plugin to collect and report basic coverage data

=head1 DESCRIPTION

Simple coverage data, file and sub coverage only. Use L<Devel::Cover> if you
want deep coverage stats.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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

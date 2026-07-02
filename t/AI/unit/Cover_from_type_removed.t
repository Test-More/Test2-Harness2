use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression coverage for ticket #150 (81): --cover-from-type was never read (the
# type hint was dropped for --cover-from, which auto-detects by file extension),
# so the option was a misleading dead knob. It has been deleted. The functional
# --cover-maybe-from-type option (read by get_coverage_tests) still works.

use App::Yath2::Plugin::Cover;

my @options = @{App::Yath2::Plugin::Cover->options->options};

subtest '--cover-from-type option is gone' => sub {
    my @ft = grep { $_->field eq 'from_type' } @options;
    is(scalar(@ft), 0, "no 'from_type' option is defined");

    like(
        dies { App::Yath2::Plugin::Cover->options->process_args(['--cover-from-type', 'json'], skip_posts => 1) },
        qr/not a valid option/,
        "--cover-from-type is rejected as an unknown option",
    );
};

subtest '--cover-maybe-from-type still works' => sub {
    my ($mft) = grep { $_->field eq 'maybe_from_type' } @options;
    ok($mft, "maybe_from_type option still defined");

    my $state = App::Yath2::Plugin::Cover->options->process_args(['--cover-maybe-from-type', 'json'], skip_posts => 1);
    is($state->{settings}->cover->maybe_from_type, 'json', "--cover-maybe-from-type parses and stores its value");

    # Its description must no longer dangle a reference to the deleted from_type.
    unlike($mft->description, qr/from_type/, "maybe_from_type description no longer references the deleted from_type");
};

done_testing;

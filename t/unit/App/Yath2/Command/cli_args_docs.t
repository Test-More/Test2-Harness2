use Test2::V0 -target => 'App::Yath2::Command';
# HARNESS-DURATION-SHORT

use ok $CLASS;

# The base class bridges cli_args (a single usage string) into the
# doc-generator interface (doc_args), which cli_help/generate_pod render as a
# [COMMAND ARGUMENTS] section. Regression coverage for TODO-87.

subtest base_defaults => sub {
    is($CLASS->cli_args, '', "cli_args defaults to empty string");
    is([$CLASS->doc_args], [], "doc_args bridges empty cli_args to an empty list");
};

subtest bridge => sub {
    {
        package My::Cmd::WithArgs;
        our @ISA = ('App::Yath2::Command');
        sub cli_args { "[--] some_arg [another]" }
    }
    {
        package My::Cmd::NoArgs;
        our @ISA = ('App::Yath2::Command');
        sub cli_args { "" }
    }

    is(
        [My::Cmd::WithArgs->doc_args],
        ["[--] some_arg [another]"],
        "doc_args returns the cli_args string when non-empty",
    );

    is([My::Cmd::NoArgs->doc_args], [], "doc_args returns empty list when cli_args is empty");
};

# A real surviving command that requires positional args.
use App::Yath2::Command::failed;
use App::Yath2::Command::abort;

subtest cli_help => sub {
    my $help = App::Yath2::Command::failed->cli_help;
    like($help, qr/\[COMMAND ARGUMENTS\]/, "failed cli_help shows a COMMAND ARGUMENTS section");
    like($help, qr/event_log\.jsonl/, "failed cli_help includes the log-file argument");

    my $none = App::Yath2::Command::abort->cli_help;
    unlike($none, qr/\[COMMAND ARGUMENTS\]/, "empty-cli_args command shows no COMMAND ARGUMENTS section");
};

subtest generate_pod => sub {
    my $pod = App::Yath2::Command::failed->generate_pod;
    like($pod, qr/^=head2 COMMAND ARGUMENTS$/m, "failed generate_pod shows a COMMAND ARGUMENTS section");
    like($pod, qr/event_log\.jsonl/, "failed generate_pod includes the log-file argument");

    my $none = App::Yath2::Command::abort->generate_pod;
    unlike($none, qr/COMMAND ARGUMENTS/, "empty-cli_args command generates no COMMAND ARGUMENTS section");
};

done_testing;

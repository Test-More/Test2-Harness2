package App::Yath2::Command::client::publish;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

use File::Spec;
use Test2::Harness2::Util qw/read_file/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Getopt::Yath;

include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::WebClient',
    'App::Yath2::Options::Publish' => [qw/mode/],
);

sub name { "client-publish" }

sub group { "web client" }

sub summary { "Publish a log file to a yath web server" }

sub description {
    return <<"    EOT";
Publish a log file to a yath web server. (API key is required)
    EOT
}

sub run {
    my $self = shift;

    my $args     = $self->args;
    my $settings = $self->settings;

    shift @$args if @$args && $args->[0] eq '--';

    my $log = shift @$args or die "You must specify a log file";
    die "'$log' is not a valid log file"       unless -f $log;
    die "'$log' does not look like a log file" unless $log =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $api_key = $settings->webclient->api_key or die "No API key was specified.\n";
    my $url     = $settings->webclient->url     or die "No URL specified.\n";
    my $mode    = $settings->publish->mode      or die "No MODE specified.\n";
    my $project = $settings->yath->project      or die "No project specified.\n";

    $url =~ s{/+$}{}g;

    # Lazily require the HTTP stack (mirrors Plugin/YathUI.pm's upload path):
    # every other HTTP consumer in the dist requires HTTP::Tiny on demand, and
    # HTTP::Tiny::Multipart is an optional (RuntimeSuggests) dep, so error
    # clearly if it is missing rather than failing at compile time (ticket #94).
    require HTTP::Tiny;
    eval { require HTTP::Tiny::Multipart; 1 } or die "To use `client-publish` you must install HTTP::Tiny::Multipart.\n";

    my ($filename) = reverse File::Spec->splitpath($log);

    my $http = HTTP::Tiny->new;
    my $res  = $http->post_multipart(
        "$url/upload" => {
            mode     => $mode,
            api_key  => $api_key,
            project  => $project,
            action   => 'upload log',
            json     => 1,
            log_file => {
                filename => $filename,
                # Upload the raw bytes on disk (no_decompress): a .jsonl.gz/.bz2
                # log must reach the server compressed, exactly as the old
                # `log_file => [$log]` file-part sent it.
                content  => read_file($log, no_decompress => 1),
            },
        },
    );

    if ($res->{success}) {
        my $body = $res->{content};

        # A 200 does not guarantee a JSON body: proxies/maintenance pages return
        # HTML, and (with allow_nonref) a bare-scalar JSON body decodes to a
        # non-hashref. Guard both so we surface a clean error instead of a
        # decode_json longmess or a 'Not a HASH reference' deref (ticket #153).
        my $data;
        my $ok = eval { $data = decode_json($body); 1 };

        unless ($ok && ref($data) eq 'HASH') {
            print STDERR "$res->{status} $res->{reason}\n";
            print STDERR "Server returned a 200 but the body is not a JSON object:\n";
            print STDERR $body, "\n";
            return 1;
        }

        print "$_\n" for @{$data->{messages} // []};

        if (defined $data->{run_uuid}) {
            print "\nView run at: $url/view/$data->{run_uuid}\n\n";
        }
        else {
            warn "Upload may have succeeded, but the server did not return a run_uuid.\n";
        }

        return 0;
    }
    else {
        print STDERR "$res->{status} $res->{reason}\n";
        return 1;
    }
}


1;

__END__

=head1 POD IS AUTO-GENERATED

package App::Yath2::Command::client::recent;
use strict;
use warnings;

our $VERSION = '2.000000';

# NOTE (ticket #45): this command used to inherit from App::Yath2::Command::recent,
# which has moved to reference/old_db as part of retiring the old DBIx::Class
# DB/web layer. It is HTTP-only (it never touched the DB), so rather than stub it
# we make it self-contained: the small amount of display + HTTP-fetch logic it
# needed from the old parent is inlined here.
use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase;

use Term::Table;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Getopt::Yath;

include_options(
    'App::Yath2::Options::Yath',
    'App::Yath2::Options::Recent',
    'App::Yath2::Options::WebClient',
);

sub name { "client-recent" }

sub summary { "Show a list of recent runs on a yath web server" }

sub group { "web client" }

sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will find the last several runs from a yath web server
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    my $yath   = $settings->yath;
    my $recent = $settings->recent;

    my ($is_term, $use_color) = (0, 0);
    if (-t STDOUT) {
        require Term::Table::Cell;
        $is_term   = 1;
        $use_color = eval { require Term::ANSIColor; 1 };
    }

    my $project = $yath->project // die "--project is a required argument.\n";
    my $count   = $recent->max || 10;
    my $user    = $settings->yath->user;

    my $data = $self->get_data($project, $count, $user) or die "Could not get any data.\n";

    @$data = reverse @$data;

    my $url = $settings->webclient->url;
    $url =~ s{/$}{}g if $url;

    my $header = [qw/Time Duration Status Pass Fail Retry/, "Run ID"];
    push @$header => 'Link' if $url;

    my $rows = [];
    for my $run (@$data) {
        push @$rows => [@{$run}{qw/added duration status passed failed retried run_id/}];

        if ($url) {
            push @{$rows->[-1]} => $run->{status} ne 'broken' ? "$url/view/$run->{run_id}" : "N/A";
        }

        my $color;
        if    ($run->{status} eq 'broken')   { $color = "magenta" }
        elsif ($run->{status} eq 'pending')  { $color = "blue" }
        elsif ($run->{status} eq 'running')  { $color = "blue" }
        elsif ($run->{status} eq 'canceled') { $color = "yellow" }
        elsif ($run->{failed})               { $color = "bold red" }
        elsif ($run->{retried})              { $color = "bold cyan" }
        elsif ($run->{passed})               { $color = "bold green" }

        if ($use_color && $color) {
            $_ = Term::Table::Cell->new(value => $_, value_color => Term::ANSIColor::color($color), reset_color => Term::ANSIColor::color("reset"))
                for @{$rows->[-1]};
        }
    }

    my $table = Term::Table->new(
        header => $header,
        rows   => $rows,
    );

    print "$_\n" for $table->render;

    return 0;
}

sub get_data {
    my $self = shift;
    my ($project, $count, $user) = @_;

    return $self->get_from_http($project, $count, $user) // die "Could not get data from the server.\n";
}

sub get_from_http {
    my $self = shift;
    my ($project, $count, $user) = @_;

    my $settings = $self->settings;

    require HTTP::Tiny;
    my $ht  = HTTP::Tiny->new();
    my $url = $settings->webclient->url or return;
    $url =~ s{/$}{}g;
    $url .= "/recent/$project/$user";
    my $res = $ht->get($url);

    die "Could not get recent runs from '$url'\n$res->{status}: $res->{reason}\n$res->{content}\n"
        unless $res->{success};

    return decode_json($res->{content});
}

1;

__END__

=head1 POD IS AUTO-GENERATED

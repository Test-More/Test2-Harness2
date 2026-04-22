package App::Yath::Script::V2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Cwd();
use File::Spec();
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/clean_path/;
use Getopt::Yath::Settings;
use App::Yath2;

my $INSTANCE;

sub do_begin {
    my $class = shift;
    my %params = @_;

    my $script      = $params{script};
    my $argv        = $params{argv} // [];
    my $config      = $params{config};
    my $user_config = $params{user_config};

    $script = clean_path($script) if $script;

    my $orig_argv      = [@$argv];
    my $orig_tmp       = File::Spec->tmpdir();
    my $orig_tmp_perms = ((stat($orig_tmp))[2] & 07777);
    my $orig_inc       = [@INC];

    my $base_file = $config || $user_config;
    my $cwd = clean_path(Cwd::getcwd());

    my $base_dir;
    if ($base_file) {
        my ($v, @d) = File::Spec->splitpath($base_file);
        pop @d;
        $base_dir = clean_path(File::Spec->catpath($v, @d));
    }
    elsif ($cwd) {
        my ($v, @d) = File::Spec->splitpath($cwd);
        $base_dir = clean_path(File::Spec->catpath($v, @d));
    }

    $ENV{SYSTEM_TMPDIR} = $orig_tmp;

    my $settings = Getopt::Yath::Settings->new(
        yath => {
            script => $script,

            scan_options => {},

            config_file      => $config      || '',
            user_config_file => $user_config || '',

            base_dir  => $base_dir,
            new_argv  => $argv,
            orig_argv => $orig_argv,
            orig_inc  => $orig_inc,
            orig_tmp  => $orig_tmp,

            orig_tmp_perms => $orig_tmp_perms,

            cwd   => $cwd,
            start => time(),
        },
    );

    $INSTANCE = App::Yath2->new(
        settings => $settings,
        argv     => $argv,
    );
}

sub do_runtime { $INSTANCE->run() }

1;

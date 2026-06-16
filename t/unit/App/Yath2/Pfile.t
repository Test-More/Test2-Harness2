use Test2::V0 -target => 'App::Yath2::Pfile';
use Test2::Tools::Spec;

use File::Temp qw/tempdir/;
use File::Spec;
use Sys::Hostname qw/hostname/;

use Test2::Harness2::Util::File::JSON;

use App::Yath2::Pfile;

my $VERSION = $App::Yath2::Pfile::VERSION;

# A minimal stand-in for Getopt::Yath::Settings: find_pfile only ever calls
# $settings->harness and then accessors on the result.
{

    package MockHarness;

    sub new { my ($c, %p) = @_; return bless {%p}, $c }
    sub persist_file { $_[0]->{persist_file} }
    sub persist_dir  { $_[0]->{persist_dir} }
    sub project      { $_[0]->{project} }

    package MockSettings;

    sub new { my ($c, %p) = @_; return bless {harness => MockHarness->new(%p)}, $c }
    sub harness { $_[0]->{harness} }
}

sub write_pfile {
    my (%data) = @_;
    my $dir   = tempdir(CLEANUP => 1);
    my $path  = File::Spec->catfile($dir, 'yath-persist.json');
    my %full  = (
        pid      => $$,
        dir      => $dir,
        version  => $VERSION,
        user     => $ENV{USER},
        hostname => hostname(),
        %data,
    );
    Test2::Harness2::Util::File::JSON->new(name => $path)->write(\%full);
    return ($path, $dir);
}

tests data_accessors => sub {
    my ($path, $dir) = write_pfile();

    my $pfile = App::Yath2::Pfile->new(path => $path);
    isa_ok($pfile, [$CLASS], "got a Pfile");
    is($pfile->path, $path, "path accessor");

    my $data = $pfile->data;
    is($data->{dir}, $dir, "data carries the dir");
    is($data->{pid}, $$,   "data carries the pid");
    is($data->{pfile_path}, $path, "pfile_path filled in from path");

    is($pfile->workdir, $dir, "workdir derived from dir");
    is($pfile->dir,     $dir, "dir accessor");
    is($pfile->pid,     $$,   "pid accessor");

    ref_is($pfile->data, $data, "data is cached");
};

tests pfile_path_preserved => sub {
    my ($path, $dir) = write_pfile(pfile_path => '/already/set');
    my $pfile = App::Yath2::Pfile->new(path => $path);
    is($pfile->data->{pfile_path}, '/already/set', "existing pfile_path is not overwritten");
};

tests describe => sub {
    my ($path, $dir) = write_pfile();
    my $pfile = App::Yath2::Pfile->new(path => $path);

    is(
        $pfile->describe,
        "\nFound: $path\n  PID: $$\n  Dir: $dir\n\n",
        "describe matches the which/watch banner exactly",
    );
};

tests find => sub {
    my ($path, $dir) = write_pfile();

    my $settings = MockSettings->new(persist_file => $path);

    my $pfile = App::Yath2::Pfile->find($settings);
    isa_ok($pfile, [$CLASS], "find returned a Pfile");
    is($pfile->path,    $path, "found the right pfile path");
    is($pfile->workdir, $dir,  "workdir resolves through find");

    my $missing = MockSettings->new(persist_file => File::Spec->catfile($dir, 'nope.json'));
    is(App::Yath2::Pfile->find($missing), undef, "find returns undef when no pfile is present");

    like(
        dies { App::Yath2::Pfile->find() },
        qr/Settings is a required argument/,
        "settings is required",
    );
};

done_testing;

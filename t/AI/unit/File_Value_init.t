use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Util::File::Value;

# Regression coverage for #154 finding 48: Value::init now chains SUPER::init, so
# the required-name croak and the fh-constructor-arg handling are restored; DONE=1
# stays deliberate (a value file is complete at read time), and reset() re-asserts
# DONE so a newline-less value survives a re-read.

my $C = 'Test2::Harness2::Util::File::Value';

subtest 'required name is enforced (SUPER::init restored)' => sub {
    like(dies { $C->new() }, qr/'name' is a required attribute/, "Value->new without a name croaks");
};

subtest 'the fh constructor arg is honored (SUPER::init restored)' => sub {
    my ($fh, $file) = tempfile("t154-value-XXXXXX", TMPDIR => 1, UNLINK => 1);
    print $fh "the-value";    # no trailing newline
    close($fh);

    open(my $rh, '<', $file) or die "open: $!";
    my $v = $C->new(name => $file, fh => $rh);
    is($v->_init_fh, $rh, "fh constructor arg saved to _INIT_FH");
    is($v->fh, $rh, "fh() returns the injected handle");
};

subtest 'read_line surfaces a newline-less value, and still does after reset' => sub {
    my ($fh, $file) = tempfile("t154-value-XXXXXX", TMPDIR => 1, UNLINK => 1);
    print $fh "the-value";    # no trailing newline
    close($fh);

    my $v = $C->new(name => $file);
    ok($v->done, "a value file is done at construction");
    is($v->read_line, "the-value", "newline-less value read (DONE => surfaced; chomp is a no-op)");

    $v->reset;
    ok($v->done, "reset re-asserts DONE for a value file");
    is($v->read_line, "the-value", "still surfaces the newline-less value after reset");
};

done_testing;

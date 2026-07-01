use Test2::V0;
use v5.38;

use Test2::Formatter::Test2;

# Chunk 7 / ticket #43 rendering contract: a system-load snapshot
# (harness_system facet) is a global signal, NOT a test event. The terminal
# formatter must:
#   * never render it as a line (it used to leak as an INTERNAL json dump), and
#   * fold the latest cpu/mem % into the TTY status bar.

sub new_formatter {
    my $buf = '';
    open(my $fh, '>', \$buf) or die "could not open in-memory fh: $!";
    my $fmt = Test2::Formatter::Test2->new(
        io       => $fh,
        tty      => 1,    # force the status bar path
        progress => 1,
        color    => 0,    # no ansi, so assertions match plain text
        verbose  => 1,
    );
    return ($fmt, \$buf);
}

subtest 'harness_system renders no line and is not counted' => sub {
    my ($fmt, $buf) = new_formatter();

    $fmt->write(undef, undef, {harness_system => {cpu_pct => 50, mem_pct => 10, load_avg => [0.3, 0.4, 0.5], ncpu => 32}});

    is($$buf, '', "system-load event produced no rendered line");
    is($fmt->ecount, 0, "system-load event did not bump the event count");
};

subtest 'status bar shows cpu and memory percentage' => sub {
    my ($fmt, $buf) = new_formatter();

    $fmt->set_system_load({cpu_pct => 75, mem_pct => 20});

    my $status = $fmt->render_status;
    like($status, qr/Cpu:75%/, "status bar carries the cpu percentage");
    like($status, qr/Mem:20%/, "status bar carries the memory percentage");
};

subtest 'set_system_load via a written event also feeds the status bar' => sub {
    my ($fmt, $buf) = new_formatter();

    $fmt->write(undef, undef, {harness_system => {cpu_pct => 5, mem_pct => 95}});

    my $status = $fmt->render_status;
    like($status, qr/Cpu:5%/,  "cpu percentage from the event reached the status bar");
    like($status, qr/Mem:95%/, "memory percentage from the event reached the status bar");
};

subtest 'no status segment before any snapshot, and a partial snapshot is tolerated' => sub {
    my ($fmt, $buf) = new_formatter();

    unlike($fmt->render_status, qr/Cpu:|Mem:/, "no cpu/mem segment before a snapshot arrives");

    # cpu_pct is undef on the sampler's very first reading; show only what we have.
    $fmt->set_system_load({mem_pct => 42});
    my $status = $fmt->render_status;
    unlike($status, qr/Cpu:/, "no cpu segment when cpu_pct is undef");
    like($status,   qr/Mem:42%/, "memory percentage still shown");
};

subtest 'normal events still render' => sub {
    my ($fmt, $buf) = new_formatter();

    $fmt->write(undef, undef, {assert => {pass => 1, details => "a real assertion"}});
    like($$buf, qr/a real assertion/, "an assert event still renders a line");
};

done_testing;

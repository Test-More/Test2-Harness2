#!/usr/bin/env perl
use strict;
use warnings;


die "No directory specified" unless @ARGV;
chdir($ARGV[0]) or die "Could not chdir to $ARGV[0]";

unshift @INC => './lib';

for my $base ('./lib/App/Yath2/Options', './lib/App/Yath2/Plugin') {
    opendir(my $dh, $base) or die "Could not open dir '$base': $!";

    for my $file (readdir($dh)) {
        next unless $file =~ m/\.pm$/;
        my $fq = "$base/$file";

        my $rel = $fq;
        $rel =~ s{^\./lib/}{}g;

        my $pkg = $rel;
        $pkg =~ s{/}{::}g;
        $pkg =~ s{\.pm$}{}g;

        require $rel;

        next unless $pkg->can('options');
        my $options = $pkg->options or next;

        # $options is a Getopt::Yath::Instance. Render every option group it
        # owns; 'applicable => 1' forces all options to render without needing a
        # settings object to gate them.
        my $opt_docs = $options->docs('pod', head => 3, applicable => 1);
        die "No option docs for $file?" unless $opt_docs;

        my $pod = "=head1 PROVIDED OPTIONS\n\n" . $opt_docs . "\n";

        my $found;
        my @lines;
        open(my $fh, '<', $fq) or die "Could not open file '$fq' for reading: $!";
        while (my $line = <$fh>) {
            if ($line eq "=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED\n") {
                $found++;
                push @lines => $pod;
                next;
            }

            push @lines => $line;
        }
        close($fh);

        next unless $found;

        open($fh, '>', $fq) or die "Could not open file '$fq' for writing: $!";
        print $fh @lines;
        close($fh);
    }
}

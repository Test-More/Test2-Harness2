package Test2::Harness2::LogLayout;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use Exporter qw/import/;

# Single canonical source for on-disk paths inside a yath log tree.
# Collectors and Log readers import these so the path templates live
# in one place.
#
# All returned paths are relative to the log root (no leading '/'),
# extension-less in the logical sense -- callers append '.json',
# '.jsonl', '.zst', etc. at their own layer.
#
# Layout (post new_log_refactor):
#
#   services/<id>/                          -- global (non-run) services
#   runs/<run_id>/                          -- run collector base
#   runs/<run_id>/services/<id>/            -- run-scoped services
#   runs/<run_id>/jobs/<id>/<try>/          -- per-job per-try collector base
#
# Each collector base directory hosts the standard trio:
#   spec.jsonl.zst    -- one row per startup
#   events.jsonl.zst  -- pipeline output, append-only
#   report.jsonl.zst  -- one row per shutdown

our @EXPORT_OK = qw/
    run_dir
    job_dir
    services_global_dir
    services_run_dir
    service_global_dir
    service_run_dir
    collector_base_dir
/;

sub run_dir {
    my ($run_id) = @_;
    croak "run_id is required" unless defined $run_id && length $run_id;
    return "runs/$run_id";
}

sub job_dir {
    my ($run_id, $job_id, $job_try) = @_;
    croak "run_id is required"  unless defined $run_id  && length $run_id;
    croak "job_id is required"  unless defined $job_id  && length $job_id;
    croak "job_try is required" unless defined $job_try && length $job_try;
    return "runs/$run_id/jobs/$job_id/$job_try";
}

sub services_global_dir { 'services' }

sub services_run_dir {
    my ($run_id) = @_;
    croak "run_id is required" unless defined $run_id && length $run_id;
    return "runs/$run_id/services";
}

sub service_global_dir {
    my ($name) = @_;
    croak "service name is required" unless defined $name && length $name;
    return "services/$name";
}

sub service_run_dir {
    my ($run_id, $name) = @_;
    croak "run_id is required"       unless defined $run_id && length $run_id;
    croak "service name is required" unless defined $name   && length $name;
    return "runs/$run_id/services/$name";
}

# Generic collector-base resolver. Args: type ('Service' | 'Run' | 'Job'),
# id (service name or ord int), run_id (or undef), job_try (or undef).
# Returns the collector's base directory relative to the log root.
sub collector_base_dir {
    my (%args) = @_;
    my $type    = $args{type}    or croak "'type' is required";
    my $id      = $args{id};
    my $run_id  = $args{run_id};
    my $job_try = $args{job_try};

    croak "'id' is required" unless defined $id && length $id;

    if ($type eq 'Service') {
        return defined $run_id
            ? service_run_dir($run_id, $id)
            : service_global_dir($id);
    }

    if ($type eq 'Run') {
        return run_dir($id);
    }

    if ($type eq 'Job') {
        croak "'run_id' is required for type=Job"
            unless defined $run_id && length $run_id;
        croak "'job_try' is required for type=Job"
            unless defined $job_try && length $job_try;
        return job_dir($run_id, $id, $job_try);
    }

    croak "Unknown collector type '$type' (want Service / Run / Job)";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::LogLayout - Path templates for the yath log tree.

=head1 DESCRIPTION

Single canonical source of truth for the on-disk paths inside a yath
log tree. Importable functions return I<extension-less> relative paths.
Callers append their own suffixes (C<.json>, C<.jsonl>, C<.zst>) at
their own layer.

The post-refactor layout uses one of four base directories per
collector, with each base hosting the same trio of files
(C<spec.jsonl.zst>, C<events.jsonl.zst>, C<report.jsonl.zst>):

  services/<id>/                  global services
  runs/<run_id>/                  run collector
  runs/<run_id>/services/<id>/    run-scoped services
  runs/<run_id>/jobs/<id>/<try>/  per-job per-try

=head1 EXPORTS

=over 4

=item $rel = run_dir($run_id)

Returns C<runs/$run_id>.

=item $rel = job_dir($run_id, $job_id, $job_try)

Returns C<runs/$run_id/jobs/$job_id/$job_try>.

=item $rel = services_global_dir()

Returns C<services>.

=item $rel = services_run_dir($run_id)

Returns C<runs/$run_id/services>.

=item $rel = service_global_dir($name)

Returns C<services/$name>.

=item $rel = service_run_dir($run_id, $name)

Returns C<runs/$run_id/services/$name>.

=item $rel = collector_base_dir(type => $t, id => $id, run_id => $r, job_try => $try)

Generic resolver. Picks the correct base directory for the supplied
type ('Service' | 'Run' | 'Job') and identifier triple.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut

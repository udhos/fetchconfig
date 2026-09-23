#!/usr/bin/perl
#
# 00-compile.t - every module compiles and loads.
#
# The cheapest useful test: a syntax error or a broken "use" anywhere in
# the tree fails here before any behaviour test runs. Run from the
# distribution root:  prove -I. t/00-compile.t
#
use strict;
use warnings;
use Test::More;

use File::Spec;
use File::Find;

# Find every .pm under fetchconfig/ plus the driver script.
my @modules;
find(
    sub { push @modules, $File::Find::name if /\.pm$/ },
    'fetchconfig',
);
@modules = sort @modules;

# Turn a path like fetchconfig/model/Abstract.pm into a package name.
sub path_to_pkg {
    my ($path) = @_;
    $path =~ s{\.pm$}{};
    $path =~ s{[/\\]}{::}g;
    return $path;
}

# Some models pull in optional transport modules (Net::OpenSSH, Net::SNMP,
# Net::TFTP, LWP::UserAgent, ...). On a host where an operator has not
# installed the module for a transport they do not use, that model cannot
# load - which is a missing-prerequisite condition, not a fault in
# fetchconfig. We distinguish the two: a load failure whose message names
# a "Can't locate <Module>.pm" is reported as a skip; any other failure
# (a real syntax or logic error in our code) fails the test.
for my $path (@modules) {
    my $pkg = path_to_pkg($path);
    my $ok = eval "require $pkg; 1";
    if ($ok) {
        pass("load $pkg");
    }
    elsif (my ($missing) = $@ =~ /Can't locate (\S+?)\.pm/) {
        # First load of a module whose optional prerequisite is absent.
        (my $mod = $missing) =~ s{/}{::}g;
        SKIP: { skip("$pkg needs $mod, not installed here", 1); }
    }
    elsif ($@ =~ /Attempt to reload \S+ aborted/) {
        # A prerequisite of this module (or of one it uses) already failed
        # to load earlier in this run; Perl caches that and reports a
        # reload-abort here. Same missing-prerequisite condition, not a
        # fault in our code.
        SKIP: { skip("$pkg depends on a module skipped above", 1); }
    }
    else {
        fail("load $pkg");
        diag($@);
    }
}

# The driver is a script, not a module. Compile it with perl -c; treat a
# missing optional prerequisite as a skip, a real error as a failure.
{
    my $out = qx{$^X -I. -c fetchconfig.pl 2>&1};
    if ($out =~ /syntax OK/) {
        pass('fetchconfig.pl compiles (perl -c)');
    }
    elsif ($out =~ /Can't locate (\S+?)\.pm/) {
        my $mod = $1; $mod =~ s{/}{::}g;
        SKIP: { skip("fetchconfig.pl needs $mod, not installed here", 1); }
    }
    else {
        fail('fetchconfig.pl compiles (perl -c)');
        diag($out);
    }
}

done_testing();

#!/usr/bin/perl
#
# 59-fc-snmp-inventory.t - smoke test for tools/fc-snmp-inventory.pl, the
# read-only SNMP inventory probe. The probe drives fetchconfig::SNMPInventory,
# so its behaviour against a real device is already covered by t/57; here we only
# check that it compiles, reports its version (and the engine version), prints
# usage, and fails an argument error with the documented exit code. Spawned as a
# child process because it is a script, not a module.
#
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# The probe does `use Net::SNMP;` at compile time; if the library is absent this
# machine can't run the inventory feature at all (same prerequisite as t/57), so
# treat it as a skip rather than a failure.
eval { require Net::SNMP; 1 }
    or plan skip_all => 'Net::SNMP not installed (SNMP inventory prerequisite)';

my $probe = "$Bin/../tools/fc-snmp-inventory.pl";
plan skip_all => "probe not found at $probe" unless -f $probe;

plan tests => 7;

# run the probe with the same perl; capture combined output and exit code.
sub run_probe {
    my (@args) = @_;
    my $out = qx{ $^X \Q$probe\E @args 2>&1 };
    return ($out, $? >> 8);
}

# --- compiles cleanly -------------------------------------------------------
{
    my $out = qx{ $^X -c \Q$probe\E 2>&1 };
    is($? >> 8, 0, 'probe compiles (perl -c)');
    like($out, qr/syntax OK/, 'perl -c reports syntax OK');
}

# --- -V prints the probe version and the engine version ---------------------
{
    my ($out, $rc) = run_probe('-V');
    is($rc, 0, '-V exits 0');
    like($out, qr/fc-snmp-inventory\.pl\s+\d+\.\d+/, '-V prints the probe version');
    like($out, qr/engine fetchconfig\s+\d+\.\d+/, '-V prints the engine version too');
}

# --- -h prints usage --------------------------------------------------------
{
    my ($out, $rc) = run_probe('-h');
    like($out, qr/Usage:/, '-h prints usage');
}

# --- missing HOST is a usage error (exit 2) ---------------------------------
{
    my ($out, $rc) = run_probe();
    is($rc, 2, 'missing HOST exits 2 (usage error)');
}

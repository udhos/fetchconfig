#!/usr/bin/perl
#
# fc-snmp-inventory.pl - part of fetchconfig
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# fetchconfig is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with fetchconfig; see the file COPYING. If not, write to the
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301 USA.
#
# fc-snmp-inventory.pl - probe a device's inventory data over SNMP (read-only).
#
# This drives fetchconfig's own collector (fetchconfig::SNMPInventory), so the
# "derived" result it prints is EXACTLY what the SNMP inventory feature would
# store for the device - same vendor registry, same model/serial/OS derivation,
# the same snmp-profiles.conf directives (vendor / model / oid / override /
# members, including the ".*" table-column walk), stack-entity promotion and
# sysName/sysLocation/sysContact. Use it when onboarding a device or a new
# vendor: see what SNMP exposes, what fetchconfig makes of it, and - from the
# "profile" section - which snmp-profiles.conf directive (if any) to add.
#
# It also prints the raw system group and ENTITY-MIB table it reads, so you can
# compare what is on the wire against what the engine derives from it.
#
# Nothing here writes anything or touches a device's config; it only issues SNMP
# GETs/GETNEXTs, and it never spools to the dashboard DB (that is the backup
# run's job, not this probe's). Secrets (community, v3 passphrases) are never
# printed. Requires Net::SNMP and the fetchconfig tree (it loads the modules
# from the parent directory of tools/).
#
# Output: key = value lines, grouped into sections.

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/..";               # tools/ -> the fetchconfig tree root

use Getopt::Long qw(:config no_ignore_case bundling);
use Net::SNMP;
use fetchconfig::SNMPInventory ();
use fetchconfig::Constants ();

our $VERSION = '1.2';

# ---------------------------------------------------------------------------
# OIDs - for the probe's own raw system-group + ENTITY dump ("what is on the
# wire"). The derived result comes from the engine, not from these.
# ---------------------------------------------------------------------------
my %SYS = (
    sysDescr    => '1.3.6.1.2.1.1.1.0',
    sysObjectID => '1.3.6.1.2.1.1.2.0',
    sysUpTime   => '1.3.6.1.2.1.1.3.0',
    sysContact  => '1.3.6.1.2.1.1.4.0',
    sysName     => '1.3.6.1.2.1.1.5.0',
    sysLocation => '1.3.6.1.2.1.1.6.0',
);
my @SYS_ORDER = qw(sysDescr sysObjectID sysUpTime sysName sysContact sysLocation);

my $ENT_ENTRY = '1.3.6.1.2.1.47.1.1.1.1';
my %ENT_COL = (
    2  => 'descr',          # entPhysicalDescr
    5  => 'class',          # entPhysicalClass (integer enum)
    7  => 'name',           # entPhysicalName
    8  => 'hardwareRev',    # entPhysicalHardwareRev
    9  => 'firmwareRev',    # entPhysicalFirmwareRev
    10 => 'softwareRev',    # entPhysicalSoftwareRev
    11 => 'serialNum',      # entPhysicalSerialNum
    12 => 'mfgName',        # entPhysicalMfgName
    13 => 'modelName',      # entPhysicalModelName
);
my %ENT_CLASS = (
    1 => 'other',   2 => 'unknown',     3 => 'chassis', 4  => 'backplane',
    5 => 'container', 6 => 'powerSupply', 7 => 'fan',    8  => 'sensor',
    9 => 'module', 10 => 'port',       11 => 'stack',    12 => 'cpu',
);

# ---------------------------------------------------------------------------
# Arguments  (v1.1-compatible; -P/--profile added)
# ---------------------------------------------------------------------------
my %opt = (
    community => 'public',
    version   => '2c',
    port      => 161,
    timeout   => 5,
    retries   => 1,
    level     => 'authNoPriv',
    authproto => 'sha',
    privproto => 'aes',
);
my ($want_help, $want_version);

GetOptions(
    'community|c=s' => \$opt{community},
    'version|v=s'   => \$opt{version},      # SNMP version: 1 | 2c | 3
    'port|p=i'      => \$opt{port},
    'timeout|t=i'   => \$opt{timeout},
    'retries|r=i'   => \$opt{retries},
    # SNMPv3
    'user|u=s'      => \$opt{user},
    'level|l=s'     => \$opt{level},        # noAuthNoPriv | authNoPriv | authPriv
    'authproto|a=s' => \$opt{authproto},    # md5 | sha
    'authpass|A=s'  => \$opt{authpass},
    'privproto|x=s' => \$opt{privproto},    # des | aes
    'privpass|X=s'  => \$opt{privpass},
    # listing / profile
    'inventory|i'   => \$opt{inventory},    # list every physical component (ENTITY)
    'brief|b'       => \$opt{brief},        # with -i: only components carrying a model/serial
    'profile|P=s'   => \$opt{profile},      # path to snmp-profiles.conf (default: shipped)
    'help|h|?'      => \$want_help,
    'script-version|V' => \$want_version,
) or usage(2);

if ($want_version) { print "fc-snmp-inventory.pl $VERSION (engine fetchconfig "
    . fetchconfig::Constants::version() . ")\n"; exit 0; }
usage(0) if $want_help;

my $host = shift @ARGV;
usage(2, "missing HOST") unless defined $host && length $host;
usage(2, "unexpected extra argument(s): @ARGV") if @ARGV;

my %VERMAP = ('1' => 'snmpv1', 'v1' => 'snmpv1',
              '2' => 'snmpv2c', '2c' => 'snmpv2c', 'v2c' => 'snmpv2c',
              '3' => 'snmpv3', 'v3' => 'snmpv3');
my $ver = $VERMAP{ lc $opt{version} };
usage(2, "invalid --version '$opt{version}' (use 1, 2c or 3)") unless $ver;
if ($ver eq 'snmpv3') {
    usage(2, "SNMPv3 requires --user") unless defined $opt{user} && length $opt{user};
    my $lvl = lc $opt{level};
    usage(2, "level $opt{level} requires --authpass")
        if ($lvl eq 'authnopriv' || $lvl eq 'authpriv') && !defined $opt{authpass};
    usage(2, "level authPriv requires --privpass")
        if $lvl eq 'authpriv' && !defined $opt{privpass};
}

# ---------------------------------------------------------------------------
# Build the engine option table (snmp_*) and a minimal stub model object that
# provides exactly the methods the collector calls on $mod.
# ---------------------------------------------------------------------------
my %tab = (
    snmp_community => $opt{community},
    snmp_version   => $opt{version},
    snmp_port      => $opt{port},
    snmp_timeout   => $opt{timeout},
    snmp_retries   => $opt{retries},
);
if ($ver eq 'snmpv3') {
    $tab{snmp_user}      = $opt{user};
    $tab{snmp_level}     = $opt{level};
    $tab{snmp_authproto} = $opt{authproto};
    $tab{snmp_authpass}  = $opt{authpass}  if defined $opt{authpass};
    $tab{snmp_privproto} = $opt{privproto};
    $tab{snmp_privpass}  = $opt{privpass}  if defined $opt{privpass};
}
# -i raises the capture depth to include transceivers/optics, matching the
# engine's snmp_inventory_level=2; without -i it keeps the default (chassis +
# modules + power supplies).
$tab{snmp_inventory_level} = 2 if $opt{inventory};

# Default profile file: the one shipped beside fetchconfig.pl (one level up from
# tools/). FindBin inside the engine would otherwise look under tools/.
my $profile_path = defined $opt{profile} && length $opt{profile}
                 ? $opt{profile}
                 : "$FindBin::Bin/../snmp-profiles.conf";

my $mod = ProbeMod->new($profile_path);

# ---------------------------------------------------------------------------
# One session, built by the engine's own builder (identical v1/v2c/v3 handling).
# ---------------------------------------------------------------------------
my ($session, $error) = fetchconfig::SNMPInventory->open_snmp_session($mod, $host, \%tab);
die "ERROR: cannot open SNMP session to $host: $error\n" unless defined $session;

# header (no secrets echoed)
my @ts = localtime;
printf "# fc-snmp-inventory.pl %s (engine fetchconfig %s)\n",
    $VERSION, fetchconfig::Constants::version();
printf "# host = %s   port = %d   snmp_version = %s%s\n",
    $host, $opt{port}, $opt{version},
    ($ver eq 'snmpv3' ? "   v3_user = $opt{user}   v3_level = $opt{level}" : '');
printf "# time = %04d-%02d-%02dT%02d:%02d:%02d\n",
    $ts[5]+1900, $ts[4]+1, $ts[3], $ts[2], $ts[1], $ts[0];
printf "# profile = %s\n", (-r $profile_path ? $profile_path : "$profile_path (not found)");

# Load the parsed profile once (used by the system + profile sections below).
my $prof = fetchconfig::SNMPInventory::_load_profiles($mod, \%tab);

# --- system group (raw) ---
print "\n# --- system ---\n";
my %sysval;
my ($sysoid, $ent_num);
for my $k (@SYS_ORDER) {
    my $v = snmp_get($session, $SYS{$k});
    $sysval{$k} = $v;
    kv("system.$k", $v);
    if ($k eq 'sysObjectID' && defined $v) {
        $sysoid = $v;
        ($ent_num) = $v =~ /^\.?1\.3\.6\.1\.4\.1\.(\d+)/;
        if (defined $ent_num) {
            kv("system.sysObjectID.enterprise", $ent_num);
            # vendor from the ENGINE registry (built-ins + the profile file),
            # so it matches what fetchconfig would record.
            my $vend = fetchconfig::SNMPInventory::_vendor_for($prof, $sysoid, $ent_num);
            kv("system.sysObjectID.vendor",
               (defined $vend ? $vend : "enterprise $ent_num (unknown)"));
        }
    }
    if ($k eq 'sysUpTime' && defined $v) {
        kv("system.sysUpTime.pretty", pretty_uptime($v));
    }
}

# --- ENTITY-MIB walk (raw) ---
print "\n# --- entity (ENTITY-MIB entPhysicalTable) ---\n";
my %ent;
my $ent_ok = 0;
{
    my $table = $session->get_table(-baseoid => $ENT_ENTRY);
    if (defined $table) {
        $ent_ok = 1;
        for my $oid (keys %$table) {
            next unless $oid =~ /^\Q$ENT_ENTRY\E\.(\d+)\.(.+)$/;
            my ($col, $idx) = ($1, $2);
            next unless $ENT_COL{$col};
            my $val = $table->{$oid};
            $val = $ENT_CLASS{$val} || "class$val" if $ENT_COL{$col} eq 'class';
            $ent{$idx}{ $ENT_COL{$col} } = $val;
        }
    }
}
if (!$ent_ok) {
    kv("entity.available", "no (ENTITY-MIB not implemented or not permitted: "
        . ($session->error || 'empty') . ")");
}
else {
    kv("entity.rows", scalar keys %ent);
    my @chassis = sort { $a <=> $b } grep { ($ent{$_}{class} || '') eq 'chassis' } keys %ent;
    kv("entity.chassis.count", scalar @chassis);
    my $ci = 0;
    for my $idx (@chassis) {
        $ci++;
        for my $f (qw(descr name mfgName modelName serialNum hardwareRev firmwareRev softwareRev)) {
            kv("entity.chassis.$ci.$f", $ent{$idx}{$f}) if defined $ent{$idx}{$f};
        }
    }
}

# full component inventory (optional: -i)
if ($opt{inventory} && $ent_ok) {
    my $hdr = $opt{brief}
        ? "components carrying a model or serial; -i -b"
        : "all physical components; -i";
    print "\n# --- inventory ($hdr) ---\n";
    my $n = 0;
    for my $idx (sort { $a <=> $b } keys %ent) {
        my $r = $ent{$idx};
        if ($opt{brief}) {
            my $m = $r->{modelName};
            my $s = $r->{serialNum};
            my $has_id = (defined $m && length $m && $m ne 'N/A')
                      || (defined $s && length $s && $s ne 'N/A');
            next unless $has_id;
        }
        $n++;
        for my $f (qw(class name modelName serialNum softwareRev)) {
            kv("inventory.$n.$f", $r->{$f}) if defined $r->{$f} && length $r->{$f};
        }
    }
    kv("inventory.shown", $n) if $opt{brief};
}

# --- profile: which snmp-profiles.conf directives match this device ---
# This is the onboarding view: it shows what config is driving the result (and,
# where a field is still blank, which directive you could add).
print "\n# --- profile (snmp-profiles.conf directives matching this device) ---\n";
if (!defined $sysoid) {
    kv("profile.note", "no sysObjectID - cannot match profile directives");
}
else {
    my $vend = fetchconfig::SNMPInventory::_vendor_for($prof, $sysoid, $ent_num);
    kv("profile.vendor", defined $vend ? $vend : "(none - would print 'unknown')");
    my $pm = fetchconfig::SNMPInventory::_model_for($prof, $sysoid);
    kv("profile.model_map", defined $pm ? $pm : "(none)");
    for my $f (qw(model serial os_version)) {
        my $ov = fetchconfig::SNMPInventory::_override_field($prof, $f, $sysoid, $ent_num);
        kv("profile.override.$f", $ov
            ? ("source=" . $ov->[0] . (defined $ov->[1] ? "  regex=" . $ov->[1] : "")
               . ($ov->[2] ? "  (.* column walk)" : "")) : "(none)");
        my $od = fetchconfig::SNMPInventory::_override_oid($prof, $f, $sysoid, $ent_num);
        kv("profile.oid.$f", $od
            ? ("oid=" . $od->[0] . (defined $od->[1] ? "  regex=" . $od->[1] : "")
               . ($od->[2] ? "  (.* column walk)" : "")) : "(none)");
    }
    my $ms = fetchconfig::SNMPInventory::_members_for($prof, $sysoid, $ent_num);
    if ($ms) {
        kv("profile.members", "serial=" . ($ms->[0] // '?')
            . "  model=" . ($ms->[1] // '-')
            . "  name="  . ($ms->[2] // '-')
            . "  os="    . ($ms->[3] // '-'));
    }
    else { kv("profile.members", "(none)"); }
}

# --- derived: the fetchconfig engine result (exactly what inventory stores) ---
print "\n# --- derived (fetchconfig engine result; see 'profile'/'entity' above"
    . " for provenance) ---\n";
my $res = eval { fetchconfig::SNMPInventory->_collect_session($mod, $session, \%tab) };
my $derr = $@;
if (!$res) {
    my $msg = $derr || "no usable inventory (ENTITY-MIB empty/unreachable and no profile fallback)";
    $msg =~ s/\s+$//;
    kv("derived.status", "failed ($msg)");
}
else {
    kv("derived.status",       'successful');
    kv("derived.manufacturer", $res->{vendor});
    kv("derived.vendor_raw",   $res->{vendor_raw}) if defined $res->{vendor_raw}
        && (!defined $res->{vendor} || $res->{vendor_raw} ne $res->{vendor});
    kv("derived.model",        $res->{model});
    kv("derived.serial",       $res->{serial});
    kv("derived.os_version",   $res->{os_version});
    kv("derived.sysname",      $res->{sysname});
    kv("derived.syslocation",  $res->{syslocation});
    kv("derived.syscontact",   $res->{syscontact});
    kv("derived.member_count", $res->{member_count});
    kv("derived.member_serials", $res->{member_serials}) if defined $res->{member_serials};
    kv("derived.hw_set",       $res->{hw_set}) if defined $res->{hw_set};

    # --- components: the per-member/part list fetchconfig stores ---
    my $comps = $res->{components} || [];
    print "\n# --- components (" . scalar(@$comps) . " stored by fetchconfig) ---\n";
    for my $c (@$comps) {
        my $n = $c->{member_index} // '?';
        for my $f (qw(comp_class comp_position model serial sw_version fw_version hw_rev)) {
            kv("component.$n.$f", $c->{$f}) if defined $c->{$f} && length $c->{$f};
        }
        kv("component.$n.primary", 'yes') if $c->{is_primary};
    }
}

$session->close;
exit 0;

# ---------------------------------------------------------------------------
# A minimal stand-in for a fetchconfig model object: provides only the methods
# fetchconfig::SNMPInventory calls on $mod. Read-only; no device-table layering.
# ---------------------------------------------------------------------------
package ProbeMod;

sub new {
    my ($class, $profile_file) = @_;
    return bless { default_options => { snmp_profile_file => $profile_file } }, $class;
}

# effective option value: the probe's $tab, then our default_options
sub dev_option {
    my ($self, $tab, $name) = @_;
    my $v = $tab->{$name};
    $v = $self->{default_options}{$name} unless defined $v;
    return $v;
}

# a numeric option that must be a (non-negative, or positive) integer, else the
# default - same contract as fetchconfig::model::Abstract::dev_option_posint.
sub dev_option_posint {
    my ($self, $tab, $name, $default, $allow_zero) = @_;
    my $v = $self->dev_option($tab, $name);
    return $default unless defined($v) && length($v);
    my $re = $allow_zero ? qr/^\d+$/ : qr/^[1-9]\d*$/;
    return $default unless $v =~ $re;
    return $v + 0;
}

sub default_option {
    my ($self, $name) = @_;
    my $v = $self->{default_options}{$name};
    return (defined $v && length $v) ? $v : undef;
}

sub log_info  { shift; print STDERR "# info: @_\n";  }
sub log_error { shift; print STDERR "# error: @_\n"; }

package main;

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# One scalar GET. Returns the value, or undef if unreachable / not present.
sub snmp_get {
    my ($s, $oid) = @_;
    my $r = $s->get_request(-varbindlist => [$oid]);
    return undef unless defined $r;
    my $v = $r->{$oid};
    return undef unless defined $v;
    return undef if $v =~ /^(noSuchObject|noSuchInstance|endOfMibView)$/;
    $v =~ s/\s+$//;
    return $v;
}

# key = value, with a readable placeholder when a value is missing
sub kv {
    my ($k, $v) = @_;
    $v = '(unavailable)' unless defined $v && length $v;
    print "$k = $v\n";
}

sub pretty_uptime {
    my ($ticks) = @_;
    return $ticks unless $ticks =~ /^\d+$/;
    my $s = int($ticks / 100);
    my $d = int($s / 86400); $s %= 86400;
    my $h = int($s / 3600);  $s %= 3600;
    my $m = int($s / 60);    $s %= 60;
    return sprintf "%dd %02d:%02d:%02d", $d, $h, $m, $s;
}

sub usage {
    my ($rc, $msg) = @_;
    print STDERR "error: $msg\n\n" if defined $msg;
    print STDERR <<"USAGE";
fc-snmp-inventory.pl $VERSION - probe device inventory over SNMP (read-only)

Usage:
  fc-snmp-inventory.pl [options] HOST

Drives fetchconfig's own SNMP inventory collector, so the "derived" result is
exactly what the inventory feature would store: vendor / model / serial / OS
version, the per-member/part component list, and the snmp-profiles.conf
directives that matched. Also prints the raw system group and ENTITY-MIB table.
It only issues SNMP reads; it never writes to the device or the dashboard DB.

Options:
  -c, --community STR    SNMPv1/v2c community         (default: public)
  -v, --version VER      SNMP version: 1 | 2c | 3     (default: 2c)
  -p, --port N           UDP port                     (default: 161)
  -t, --timeout SEC      per-request timeout          (default: 5)
  -r, --retries N        retries                      (default: 1)
  -i, --inventory        also list every physical component (ENTITY; can be long)
  -b, --brief            with -i: list only components that carry a model or serial
  -P, --profile FILE     snmp-profiles.conf to use    (default: shipped, beside
                         fetchconfig.pl)

SNMPv3 (with -v 3):
  -u, --user NAME        security name (required for v3)
  -l, --level LEVEL      noAuthNoPriv | authNoPriv | authPriv (default: authNoPriv)
  -a, --authproto P      md5 | sha                    (default: sha)
  -A, --authpass STR     authentication passphrase
  -x, --privproto P      des | aes                    (default: aes)
  -X, --privpass STR     privacy passphrase

  -V, --script-version   print this script's version (and the engine version)
  -h, -?, --help         this help

Examples:
  fc-snmp-inventory.pl -v 2c -c public 10.0.0.1
  fc-snmp-inventory.pl -v 2c -c public -i switch01.example.net
  fc-snmp-inventory.pl -v 3 -u monitor -l authPriv -a sha -A s3cret \\
                       -x aes -X s3cret2 rtr01.example.net

Exit: 0 ok, 2 usage error, 1 SNMP session error.
USAGE
    exit($rc);
}

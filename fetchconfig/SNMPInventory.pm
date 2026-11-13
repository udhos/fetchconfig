# fetchconfig - Retrieving configuration for multiple devices
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
# $Id: SNMPInventory.pm,v 1.0 2026/11/10 00:00:00 tammer Exp $

# Model-independent SNMP device inventory collector (engine 9.80). Runs during a
# normal backup run, reads the ENTITY-MIB physical table plus the system group
# over SNMP, and derives per-device make/model/serial/OS and the stack members
# and serial-bearing field-replaceable parts. The result is written to the
# fetchconfig-web dashboard DB (schema 2.15) through the existing backup-history
# outbox (op=inv_* lines) - see fetchconfig::History and the out-of-tree design
# docs fetchconfig-inventory-db-schema.md / fetchconfig-9.80-change-request.md.
#
# This module never touches the DB itself; collect() only reads SNMP and returns
# a result the caller records through fetchconfig::Mailer (same worker/parent
# split as a backup result). open_snmp_session() is the one place v1/v2c/v3
# sessions are built, shared with fetchconfig::model::ProCurveSNMP.

package fetchconfig::SNMPInventory;

use strict;
use warnings;
use Net::SNMP ();
use FindBin ();

# --- ENTITY-MIB entPhysicalTable columns (1.3.6.1.2.1.47.1.1.1.1.<col>) --------
my $ENT = '1.3.6.1.2.1.47.1.1.1.1';
my %ENT_COL = (
    descr        => "$ENT.2",
    contained_in => "$ENT.4",
    class        => "$ENT.5",
    name         => "$ENT.7",
    hw_rev       => "$ENT.8",
    fw_rev       => "$ENT.9",
    sw_rev       => "$ENT.10",
    serial       => "$ENT.11",
    mfg          => "$ENT.12",
    model        => "$ENT.13",
);

# entPhysicalClass enumerations we care about.
my %CLASS_NAME = (
    3  => 'chassis',
    6  => 'powerSupply',
    9  => 'module',
    10 => 'transceiver',   # entPhysicalClass "port"; stored only when it has a serial (level 2)
);

# System group scalars.
my $OID_sysDescr    = '1.3.6.1.2.1.1.1.0';
my $OID_sysObjectID = '1.3.6.1.2.1.1.2.0';
my $OID_sysContact  = '1.3.6.1.2.1.1.4.0';
my $OID_sysName     = '1.3.6.1.2.1.1.5.0';
my $OID_sysLocation = '1.3.6.1.2.1.1.6.0';

# Built-in enterprise -> canonical vendor registry. Augmented/overridden by the
# optional snmp-profiles.conf (see _load_profiles). Keyed by SMI enterprise
# number (the integer after 1.3.6.1.4.1).
my %BUILTIN_VENDOR = (
    9     => 'Cisco',
    11    => 'HP',
    248   => 'Hirschmann (Belden)',
    890   => 'Zyxel Communications',
    10456 => 'PLANET Technology Corporation',
    14823 => 'Aruba Networks',          # legacy Aruba enterprise (AOS-8, Instant APs); 47196 is the newer HPE Aruba
    25506 => 'HPE Comware',
    47196 => 'HPE Aruba Networking',
);

# Built-in sysObjectID -> model registry, used only as a last-resort model
# fallback when the ENTITY-MIB carries neither entPhysicalModelName nor
# entPhysicalDescr (e.g. the old menu-only ProCurve chassis). Augmented by
# "model" lines in snmp-profiles.conf. Keyed by the full sysObjectID.
my %BUILTIN_MODEL = (
    '1.3.6.1.4.1.11.2.3.7.11.9' => 'HP J4121A ProCurve Switch 4000M',
    '1.3.6.1.4.1.11.2.3.7.11.7' => 'HP J4110A ProCurve Switch 8000M',
);

my $profiles;   # { exact,prefix,ent (vendor); model_exact,model_prefix (model) }; lazy

# --- option helpers -----------------------------------------------------------

sub _opt {
    my ($mod, $tab, $name) = @_;
    my $v = $mod->dev_option($tab, $name);
    return undef unless defined($v);
    $v =~ s/^\s+//; $v =~ s/\s+$//;
    return (length($v) ? $v : undef);
}

# Permissive boolean for the snmp_* flag options. Unlike the global
# dev_option_flag (which accepts only "on"), this also takes 1/0, yes/no,
# true/false and enable(d)/disable(d) - so snmp_inventory=1, the natural form a
# web UI emits and the documented default value, means ON rather than being
# silently read as OFF. Unset or unrecognised -> the given default.
sub flag {
    my ($class, $mod, $tab, $name, $default) = @_;
    my $v = _opt($mod, $tab, $name);
    return $default ? 1 : 0 unless defined($v);
    my $lv = lc $v;
    return 1 if $lv =~ /^(?:1|on|yes|true|y|t|enabled?)$/;
    return 0 if $lv =~ /^(?:0|off|no|false|n|f|disabled?)$/;
    return $default ? 1 : 0;
}

# Normalise the snmp_version option to a Net::SNMP version string.
sub _norm_version {
    my ($v) = @_;
    $v = '2c' unless defined($v) && length($v);
    $v = lc $v;
    return 'snmpv1'  if $v eq '1'  || $v eq 'v1'  || $v eq 'snmpv1';
    return 'snmpv2c' if $v eq '2c' || $v eq 'v2c' || $v eq 'snmpv2c' || $v eq '2';
    return 'snmpv3'  if $v eq '3'  || $v eq 'v3'  || $v eq 'snmpv3';
    return undef;
}

# Is SNMP inventory configured for this device? (credentials present, and not
# turned off). Returns one of: 'on', 'off' (explicit snmp_inventory=0 but was
# otherwise configured), 'none' (no snmp_* at all - nothing to record).
sub mode {
    my ($class, $mod, $tab) = @_;

    my $ver = _norm_version(_opt($mod, $tab, 'snmp_version'));
    # A read-WRITE community reads fine, and procurve-snmp (and some sites)
    # configure only snmp_write_community; treat either as v1/v2c credentials.
    my $community = _opt($mod, $tab, 'snmp_community')
                 // _opt($mod, $tab, 'snmp_write_community');
    my $user      = _opt($mod, $tab, 'snmp_user');

    my $has_creds = (defined($ver) && $ver eq 'snmpv3')
                      ? defined($user)
                      : defined($community);

    # "known to inventory" = has credentials, or snmp_inventory explicitly set.
    my $inv_set = defined($mod->dev_option($tab, 'snmp_inventory'));
    my $any_snmp = $has_creds || $inv_set
                 || defined(_opt($mod, $tab, 'snmp_user'));

    return 'none' unless $any_snmp;

    # snmp_inventory default on; off/0/no/false disables (permissive boolean).
    my $enabled = $class->flag($mod, $tab, 'snmp_inventory', 1);
    return 'off' unless $enabled;
    return 'off' unless $has_creds;   # configured something, but not enough to run
    return 'on';
}

# --- session builder (shared with ProCurveSNMP) -------------------------------

# open_snmp_session($mod, $dev_host, $tab) -> ($session, $error)
# Builds a Net::SNMP session from the snmp_* options. Used by the inventory
# collector (read) and by ProCurveSNMP (its read-write community arms the TFTP
# export; it passes want_write=1 so snmp_write_community is used when set).
sub open_snmp_session {
    my ($class, $mod, $dev_host, $tab, %o) = @_;

    my $ver = _norm_version(_opt($mod, $tab, 'snmp_version'));
    return (undef, "bad snmp_version") unless defined($ver);

    my $port    = _opt($mod, $tab, 'snmp_port')    // 161;
    my $timeout = $mod->dev_option_posint($tab, 'snmp_timeout', 5, 0) || 5;
    my $retries = $mod->dev_option_posint($tab, 'snmp_retries', 1, 1);

    my @common = (
        -hostname => $dev_host,
        -port     => $port,
        -timeout  => $timeout,
        -retries  => $retries,
        -version  => $ver,
    );

    if ($ver eq 'snmpv3') {
        my $user = _opt($mod, $tab, 'snmp_user');
        return (undef, "snmp_user required for SNMPv3") unless defined($user);

        my $authpass = _opt($mod, $tab, 'snmp_authpass');
        my $privpass = _opt($mod, $tab, 'snmp_privpass');

        # Level: explicit, else derived from the credentials supplied.
        my $level = lc(_opt($mod, $tab, 'snmp_level') // '');
        if (!length $level) {
            $level = !defined($authpass) ? 'noauthnopriv'
                   : !defined($privpass) ? 'authnopriv'
                   :                       'authpriv';
        }

        my @v3 = (-username => $user);
        if ($level eq 'authnopriv' || $level eq 'authpriv') {
            return (undef, "snmp_authpass required for level $level") unless defined($authpass);
            push @v3, -authprotocol => lc(_opt($mod, $tab, 'snmp_authproto') // 'sha'),
                      -authpassword => $authpass;
        }
        if ($level eq 'authpriv') {
            return (undef, "snmp_privpass required for level authPriv") unless defined($privpass);
            push @v3, -privprotocol => lc(_opt($mod, $tab, 'snmp_privproto') // 'aes'),
                      -privpassword => $privpass;
        }
        my ($session, $error) = Net::SNMP->session(@common, @v3);
        $session->translate([-octetstring => 0])                 # raw OCTET STRINGs (see below)
            if $session && $session->can('translate');
        return ($session, $error);
    }

    # v1 / v2c. A write session prefers the RW community; a read session prefers
    # the RO community but falls back to the RW one (it reads fine), so a device
    # configured with only snmp_write_community is still inventoried.
    my $community = $o{want_write}
        ? (_opt($mod, $tab, 'snmp_write_community') // _opt($mod, $tab, 'snmp_community'))
        : (_opt($mod, $tab, 'snmp_community') // _opt($mod, $tab, 'snmp_write_community'));
    return (undef, "snmp_community required") unless defined($community);

    my ($session, $error) = Net::SNMP->session(@common, -community => $community);
    # Return OCTET STRINGs raw instead of Net::SNMP's default "0x..." hex rendering
    # for any value with a non-printable byte -- so a sysName/ENTITY/member name with
    # a UTF-8 character (e.g. an umlaut) comes through as text, not hex. Other
    # translations (TimeTicks, noSuchObject, ...) are left on. (can() guard: mock
    # sessions in the test suite do not implement translate.)
    $session->translate([-octetstring => 0])
        if $session && $session->can('translate');
    return ($session, $error);
}

# --- vendor profile file ------------------------------------------------------

sub _profile_path {
    my ($mod, $tab) = @_;
    # snmp_profile_file is a default:-only option. The parsed vendor file is
    # cached process-wide (see _load_profiles), so a per-device value could not
    # take effect anyway; a device-line value is ignored, with a warning so it
    # is not dropped silently. The vendor file can hold many vendors, so one
    # fleet-wide file is the intended use.
    if (defined($tab->{snmp_profile_file}) && $mod->can('log_info')) {
        $mod->log_info("warning: snmp_profile_file is a default:-only option; ignoring the device-line value");
    }
    my $override = $mod->can('default_option')
                 ? $mod->default_option('snmp_profile_file')
                 : undef;
    return $override if defined($override) && length($override);
    # Shipped beside fetchconfig.pl (FindBin::RealBin), like the generic templates.
    return "$FindBin::RealBin/snmp-profiles.conf";
}

sub _load_profiles {
    my ($mod, $tab) = @_;
    return $profiles if defined $profiles;

    $profiles = { exact => {}, prefix => [], ent => { %BUILTIN_VENDOR },
                  model_exact => { %BUILTIN_MODEL }, model_prefix => [],
                  oid => {}, override => {}, members => { sysoid => [], ent => {} } };

    my $path = _profile_path($mod, $tab);
    if (open(my $fh, '<', $path)) {
        while (my $ln = <$fh>) {
            $ln =~ s/[\r\n]+$//;
            $ln =~ s/^\s+//; $ln =~ s/\s+$//;
            next if !length($ln) || $ln =~ /^#/;
            # vendor <enterprise-or-oid> <canonical name>
            if ($ln =~ /^vendor\s+(\S+)\s+(.+)$/) {
                my ($match, $name) = ($1, $2);
                if ($match =~ /^\d+$/)          { $profiles->{ent}{$match} = $name; }
                elsif ($match =~ /^[\d.]+$/)    {
                    $profiles->{exact}{$match} = $name;
                    push @{$profiles->{prefix}}, [$match, $name];
                }
            }
            # model <sysObjectID-or-prefix> <model name>   (sysObjectID only)
            elsif ($ln =~ /^model\s+(\S+)\s+(.+)$/) {
                my ($match, $name) = ($1, $2);
                if ($match =~ /^[\d.]+$/) {
                    $profiles->{model_exact}{$match} = $name;
                    push @{$profiles->{model_prefix}}, [$match, $name];
                }
            }
            # oid <field> <enterprise-or-sysObjectID> <OID> [<extract-regex>]
            #   field: model | serial | os_version. Read from a device with no
            #   ENTITY-MIB (e.g. a vendor's private MIB). <OID> is a plain GET of
            #   one instance (a scalar .0, or a specific table row); an <OID> ending
            #   in ".*" is a bare table-COLUMN base, walked (GETNEXT) to its first
            #   row -- so a MAC/slot-indexed serial needs no per-device index. The
            #   optional regex's first capture group (else the whole value) is used.
            elsif ($ln =~ /^oid\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(.+))?$/) {
                my ($field, $match, $oid, $re) = ($1, $2, $3, $4);
                my $walk = ($oid =~ s/\.\*$//) ? 1 : 0;   # trailing ".*" -> walk the column
                if ($field =~ /^(?:model|serial|os_version)$/ && $oid =~ /^[\d.]+$/) {
                    $profiles->{oid}{$field} ||= { sysoid => [], ent => {} };
                    if    ($match =~ /^\d+$/)    { $profiles->{oid}{$field}{ent}{$match} = [$oid, $re, $walk]; }
                    elsif ($match =~ /^[\d.]+$/) { push @{$profiles->{oid}{$field}{sysoid}}, [$match, $oid, $re, $walk]; }
                }
            }
            # override <field> <enterprise-or-sysObjectID> <source> [<extract-regex>]
            #   field: model | serial | os_version. REPLACES a present-but-wrong
            #   ENTITY value (e.g. a chipset codename like "Luton26" in
            #   entPhysicalModelName). <source> is a numeric OID (GET one instance;
            #   a ".*" suffix walks a table column like "oid") or a symbol naming
            #   already-collected data: sysdescr, entdescr, entmodel, entserial. The
            #   optional regex's first capture group (else the whole value) becomes
            #   the field; a regex miss keeps the ENTITY value.
            elsif ($ln =~ /^override\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(.+))?$/) {
                my ($field, $match, $source, $re) = ($1, $2, $3, $4);
                my $walk = ($source =~ /^[\d.]+\.\*$/ && $source =~ s/\.\*$//) ? 1 : 0;
                if ($field =~ /^(?:model|serial|os_version)$/
                    && ($source =~ /^[\d.]+$/
                        || $source =~ /^(?:sysdescr|entdescr|entmodel|entserial)$/)) {
                    $profiles->{override}{$field} ||= { sysoid => [], ent => {} };
                    if    ($match =~ /^\d+$/)    { $profiles->{override}{$field}{ent}{$match} = [$source, $re, $walk]; }
                    elsif ($match =~ /^[\d.]+$/) { push @{$profiles->{override}{$field}{sysoid}}, [$match, $source, $re, $walk]; }
                }
            }
            # members <enterprise-or-sysObjectID> serial=<col> [model=<col>] [name=<col>] [os=<col>]
            #   Record one chassis MEMBER per row of a vendor private-MIB table (like a
            #   stack), for a device that aggregates others -- e.g. an Aruba virtual
            #   controller listing its member APs in AI-AP-MIB aiAPTable. Each value is a
            #   table-COLUMN base; the engine walks the serial column (which defines the
            #   member set) and joins model/name/os by the same per-row index. serial is
            #   required. Applied on the ENTITY-less path only.
            elsif ($ln =~ /^members\s+(\S+)\s+(.+)$/) {
                my ($match, $rest) = ($1, $2);
                my %col;
                while ($rest =~ /(\w+)=(\S+)/g) {
                    my ($k, $v) = ($1, $2);   # copy out: the tests below reset $1/$2
                    $col{$k} = $v if $k =~ /^(?:serial|model|name|os)$/ && $v =~ /^[\d.]+$/;
                }
                if ($col{serial}) {   # serial column is mandatory (it enumerates the members)
                    my @spec = ($col{serial}, $col{model}, $col{name}, $col{os});
                    if    ($match =~ /^\d+$/)    { $profiles->{members}{ent}{$match} = [@spec]; }
                    elsif ($match =~ /^[\d.]+$/) { push @{$profiles->{members}{sysoid}}, [$match, @spec]; }
                }
            }
        }
        close $fh;
        # longest prefix first
        @{$profiles->{prefix}}       = sort { length($b->[0]) <=> length($a->[0]) } @{$profiles->{prefix}};
        @{$profiles->{model_prefix}} = sort { length($b->[0]) <=> length($a->[0]) } @{$profiles->{model_prefix}};
        for my $f (values %{ $profiles->{oid} }, values %{ $profiles->{override} }) {
            @{ $f->{sysoid} } = sort { length($b->[0]) <=> length($a->[0]) } @{ $f->{sysoid} };
        }
        @{ $profiles->{members}{sysoid} } =
            sort { length($b->[0]) <=> length($a->[0]) } @{ $profiles->{members}{sysoid} };
    }
    return $profiles;
}

# Canonical vendor for a sysObjectID (most-specific-first: full OID, longest OID
# prefix, enterprise number). undef if unknown.
sub _vendor_for {
    my ($p, $sysoid, $ent) = @_;
    return undef unless defined($p);
    if (defined($sysoid)) {
        return $p->{exact}{$sysoid} if exists $p->{exact}{$sysoid};
        for my $e (@{$p->{prefix}}) {
            my $pre = $e->[0];
            return $e->[1] if $sysoid eq $pre || index($sysoid, "$pre.") == 0;
        }
    }
    return $p->{ent}{$ent} if defined($ent) && exists $p->{ent}{$ent};
    return undef;
}

# Model for a sysObjectID (exact OID, then longest OID prefix). undef if unknown.
# Only a last-resort fallback: the ENTITY-MIB model/descr is preferred.
sub _model_for {
    my ($p, $sysoid) = @_;
    return undef unless defined($p) && defined($sysoid);
    return $p->{model_exact}{$sysoid} if exists $p->{model_exact}{$sysoid};
    for my $e (@{ $p->{model_prefix} || [] }) {
        my $pre = $e->[0];
        return $e->[1] if $sysoid eq $pre || index($sysoid, "$pre.") == 0;
    }
    return undef;
}

# A vendor-specific override OID for a headline field (model/serial/os_version),
# matched most-specific-first (sysObjectID exact/prefix, then enterprise number).
# Returns [OID, regex] or undef. See the "oid" directive in snmp-profiles.conf.
# Match a profile spec bucket ({ sysoid => [[prefix, a, b], ...], ent => { n => [a, b] } })
# against a device sysObjectID / enterprise, most-specific-first (full or longest-prefix
# sysObjectID, then enterprise number). Returns the stored [a, b] arrayref, or undef.
sub _spec_for {
    my ($bucket, $sysoid, $ent) = @_;
    return undef unless defined $bucket;
    if (defined($sysoid)) {
        for my $e (@{ $bucket->{sysoid} || [] }) {
            my $pre = $e->[0];
            return [ @{$e}[1 .. $#$e] ]      # drop the prefix -> [a, b]
                if $sysoid eq $pre || index($sysoid, "$pre.") == 0;
        }
    }
    return $bucket->{ent}{$ent} if defined($ent) && $bucket->{ent} && exists $bucket->{ent}{$ent};
    return undef;
}

sub _override_oid {
    my ($p, $field, $sysoid, $ent) = @_;
    return undef unless defined($p) && $p->{oid};
    return _spec_for($p->{oid}{$field}, $sysoid, $ent);
}

# An "override" spec [source, regex] for a headline field, or undef. See the
# "override" directive in snmp-profiles.conf -- unlike "oid" (which FILLS an empty
# field on an ENTITY-less device), this REPLACES a present-but-wrong ENTITY value.
sub _override_field {
    my ($p, $field, $sysoid, $ent) = @_;
    return undef unless defined($p) && $p->{override};
    return _spec_for($p->{override}{$field}, $sysoid, $ent);
}

# Fetch one value for a profile "oid"/"override" numeric-OID spec. With $walk false
# (the default) this is a plain GET of a fully-indexed instance -- the original
# behaviour, unchanged for every existing rule. With $walk true (a rule whose OID
# ended in ".*", i.e. a bare table-COLUMN base, e.g. AI-AP-MIB aiAPSerialNum) it does
# a single GETNEXT and takes the first row inside that column's subtree -- so the rule
# names the column and the engine finds the (first) row itself, with no per-device
# index to hard-code. The walk is opt-in per rule (the ".*" marker), so a plain
# instance OID on any other vendor is never second-guessed. Returns the raw value, or
# undef (no answer, a Net::SNMP exception, or a GETNEXT that left the column subtree).
sub _get_instance {
    my ($session, $oid, $walk) = @_;
    if ($walk) {
        my $n = eval { $session->get_next_request(-varbindlist => [$oid]) } or return undef;
        my ($next) = keys %$n;
        return undef unless defined($next) && index($next, "$oid.") == 0;   # must stay in the column
        my $v = $n->{$next};
        return undef if !defined($v) || $v =~ /^(?:noSuch|endOfMib)/;
        return $v;
    }
    my $r = eval { $session->get_request(-varbindlist => [$oid]) } or return undef;
    my $v = $r->{$oid};
    return undef if !defined($v) || !length($v) || $v =~ /^(?:noSuch|endOfMib)/;
    return $v;
}

# A "members" table spec [serial_col, model_col, name_col, os_col] for a device that
# aggregates others (an Aruba virtual controller's AI-AP-MIB aiAPTable), or undef.
# Matched most-specific-first like the other directives. See the "members" directive.
sub _members_for {
    my ($p, $sysoid, $ent) = @_;
    return undef unless defined($p) && $p->{members};
    return _spec_for($p->{members}, $sysoid, $ent);
}

# Walk one table COLUMN and return { index-suffix => value } for every instance under
# $col (get_table does the GET-NEXT subtree walk; works on v1 and v2c). The index
# suffix is whatever follows "$col." -- a per-row key (e.g. a MAC) joined across the
# member columns. Net::SNMP exceptions and out-of-subtree rows are dropped.
sub _walk_column {
    my ($session, $col) = @_;
    my $t = eval { $session->get_table(-baseoid => $col) } or return {};
    return {} unless ref $t eq 'HASH';
    my %out;
    for my $oid (keys %$t) {
        next unless index($oid, "$col.") == 0;
        my $v = $t->{$oid};
        next if !defined($v) || $v =~ /^(?:noSuch|endOfMib)/;
        $out{ substr($oid, length($col) + 1) } = $v;
    }
    return \%out;
}

# Build one chassis component per row of a vendor "members" table, like stack members.
# $spec = [serial_col, model_col, name_col, os_col]; the serial column enumerates the
# members, model/name/os are joined by the same per-row index. member_index is assigned
# in index order (MAC octets compared numerically). Returns the component list, or () if
# the table is empty / carries no serials.
sub _collect_members {
    my ($class, $session, $spec) = @_;
    my ($ser_col, $mod_col, $nam_col, $os_col) = @$spec;
    my $sers = _walk_column($session, $ser_col);
    return () unless %$sers;
    my $mods = $mod_col ? _walk_column($session, $mod_col) : {};
    my $nams = $nam_col ? _walk_column($session, $nam_col) : {};
    my $oses = $os_col  ? _walk_column($session, $os_col)  : {};
    # Order by the dotted-decimal index, compared component-wise (so e.g. .2 < .10).
    my @idx = sort {
        my @A = split /\./, $a; my @B = split /\./, $b;
        my $n = ($#A > $#B) ? $#A : $#B;
        my $c = 0;
        for my $k (0 .. $n) { $c = (($A[$k] // -1) <=> ($B[$k] // -1)) and last; }
        $c;
    } keys %$sers;
    my @components; my $mn = 0;
    for my $i (@idx) {
        my $serial = _trim($sers->{$i});
        next unless defined $serial;
        push @components, {
            member_index => ++$mn,
            comp_class   => 'chassis',
            comp_position=> _trim($nams->{$i}),
            model        => _trim($mods->{$i}),
            serial       => $serial,
            sw_version   => _trim($oses->{$i}),
            fw_version   => undef,
            hw_rev       => undef,
            is_primary   => 0,
        };
    }
    return @components;
}

# Resolve an "override" value for a headline field (model/serial/os_version). The
# source is a numeric OID (GET one instance) or a symbol read from already-collected
# data in %$sources (sysdescr/entdescr/entmodel/entserial). The optional regex's first
# capture group (else the whole value) is the result. Returns the new value, or undef
# to KEEP the ENTITY-derived value (no spec, empty source, GET exception, or regex
# miss / bad pattern) -- an override never blanks a field.
sub _override_value {
    my ($class, $prof, $field, $sysoid, $ent, $sources, $session) = @_;
    my $spec = _override_field($prof, $field, $sysoid, $ent) or return undef;
    my ($src, $re) = @$spec;
    my $raw;
    if ($src =~ /^[\d.]+$/) {                        # a numeric OID -> GET (or walk a column)
        $raw = _get_instance($session, $src, $spec->[2]);   # $spec->[2] = walk flag ("...*" column)
        return undef unless defined $raw;
    } else {
        $raw = $sources->{$src};                     # sysdescr / entdescr / entmodel / entserial
    }
    $raw = _trim($raw);
    return undef unless defined($raw) && length($raw);
    if (defined($re) && length($re)) {
        my $m = eval { $raw =~ /$re/ ? (defined($1) ? $1 : $raw) : undef };
        $m = _trim($m);
        return (defined($m) && length($m)) ? $m : undef;   # miss/bad pattern -> keep ENTITY value
    }
    return $raw;
}

# Fill still-empty headline fields (model/serial/os_version) from vendor-specific
# "oid" profile entries -- scalar or table-instance OIDs a device exposes in its
# private MIB when it has no ENTITY-MIB (e.g. Hirschmann hmSysGroup). Each entry is
# a plain GET of one instance OID; an optional regex's first capture group (else the
# whole value) becomes the field. Only fields still undef are fetched, so a device
# with real ENTITY data is never second-guessed.
sub _apply_override_oids {
    my ($class, $session, $prof, $sysoid, $ent, $h) = @_;
    for my $field (qw(model serial os_version)) {
        next if defined($h->{$field}) && length($h->{$field});
        my $spec = _override_oid($prof, $field, $sysoid, $ent) or next;
        my ($oid, $re, $walk) = @$spec;
        my $v = _get_instance($session, $oid, $walk);   # plain GET, or walk a ".*" column base
        next unless defined($v) && length($v);
        $v = _trim($v);
        next unless defined($v) && length($v);
        if (defined($re) && length($re)) {
            my $m = eval { $v =~ /$re/ ? (defined($1) ? $1 : $v) : undef };
            next unless defined($m) && length($m);   # regex miss or bad pattern -> skip
            $v = $m;
        }
        $h->{$field} = $v;
    }
    return $h;
}

# Best-effort OS/firmware version from sysDescr, for devices whose ENTITY-MIB
# carries no software/firmware revision (e.g. the old ProCurve chassis, whose
# sysDescr reads "... revision C.09.30, ROM C.06.01 ..."). Tries the common
# "revision <tok>" (HP) and "Version <tok>" (Cisco/others) forms. undef if none.
sub _os_from_sysdescr {
    my ($d) = @_;
    return undef unless defined($d) && length($d);
    # Require the captured token to contain a digit, so the bare words
    # "revision"/"version" (e.g. "no version info") do not match. Copy the
    # capture out first: testing $1 =~ /\d/ would itself clear $1.
    while ($d =~ /\brevision\s+([^\s,;]+)/gi) { my $v = $1; return _trim($v) if $v =~ /\d/; }
    while ($d =~ /\bversion\s+([^\s,;]+)/gi)  { my $v = $1; return _trim($v) if $v =~ /\d/; }
    return undef;
}

# --- small value helpers ------------------------------------------------------

sub _trim { my $s = shift; return undef unless defined $s; $s =~ s/^\s+//; $s =~ s/\s+$//; return (length($s) ? $s : undef); }

# A scalar system-group value, trimmed; a Net::SNMP per-varbind exception
# (noSuchObject/noSuchInstance/endOfMibView) or an empty string -> undef.
sub _clean_scalar {
    my ($v) = @_;
    return undef unless defined $v;
    return undef if $v =~ /^(?:noSuch|endOfMib)/;
    return _trim($v);
}

# entPhysicalFirmwareRev placeholders. Many agents report a stub here instead of a
# real firmware/ROMMON version: a Cisco Catalyst 9000 (IOS-XE) returns "0.1" on the
# chassis and "" on every other entity, and the real "System Bootstrap, Version ..."
# is not reachable over SNMP on that platform at all (not in entPhysicalFirmwareRev,
# OLD-CISCO-SYSTEM-MIB::romId, or CISCO-ENTITY-ASSET-MIB). Treat these placeholders
# as "no firmware" so fw_version is left NULL rather than storing a misleading "0.1".
# Real revisions ("17.8.01r", "V05", ...) pass through unchanged.
my %FW_STUB = map { ($_ => 1) }
    ('0', '0.0', '0.1', '0.0.0', 'n/a', 'na', 'none', 'unknown',
     'unavailable', '(unavailable)', 'not available');
sub _fw_clean {
    my $v = _trim(shift);
    return undef unless defined $v;
    return undef if $FW_STUB{lc $v};
    return undef if $v =~ /^0+(?:\.0+)+$/;   # any all-zero dotted form (0.0, 0.00.0, ...)
    return $v;
}

# --- collect ------------------------------------------------------------------

# collect($mod, $dev_id, $dev_host, $tab) -> \%result
#   status => 'none'|'off'|'disabled'|'failed'|'successful'
#     none/off -> caller records nothing / records 'disabled' per the emission rule.
#   On 'successful': headline {} + components [].
sub collect {
    my ($class, $mod, $dev_id, $dev_host, $tab) = @_;

    my $m = $class->mode($mod, $tab);
    return { status => 'none' }     if $m eq 'none';
    return { status => 'disabled' } if $m eq 'off';

    my $source = 'snmp';
    my ($session, $error) = $class->open_snmp_session($mod, $dev_host, $tab);
    if (!defined($session)) {
        $mod->log_error("SNMP inventory: could not open session: $error") if $mod->can('log_error');
        return { status => 'failed', source => $source, error => $error };
    }

    my $res = eval { $class->_collect_session($mod, $session, $tab) };
    my $err = $@;
    $session->close;

    if (!$res) {
        my $msg = $err || "no usable inventory (ENTITY-MIB empty or unreachable)";
        $msg =~ s/\s+$//;
        $mod->log_error("SNMP inventory failed: $msg") if $mod->can('log_error');
        return { status => 'failed', source => $source, error => $msg };
    }

    $res->{status} = 'successful';
    $res->{source} = $source;
    return $res;
}

# Single multi-column GET-BULK walk of the ENTITY-MIB. $cols maps field => column
# base OID. Returns \%row (entPhysicalIndex => { field => value }), or undef on a
# GET-BULK error so the caller can fall back to per-column get_table. One bulk
# stream carries every column, so the whole table costs ~(#rows / max-repetitions)
# PDUs instead of that many PER column. entPhysicalIndex is a single integer, so
# the OID under a column base is base.<index>.
sub _walk_entity {
    my ($session, $cols, $maxrep) = @_;
    $maxrep = 25 unless defined($maxrep) && $maxrep > 0;
    return undef unless $session->can('get_bulk_request');

    my %row;
    my %cur = %$cols;        # field => next-start OID (begins at the column base)
    my %done;
    my $rounds = 0;
    while (1) {
        my @fields = grep { !$done{$_} } sort keys %cur;
        last unless @fields;
        last if ++$rounds > 100000;      # safety valve against a misbehaving agent

        my $r = $session->get_bulk_request(
            -nonrepeaters   => 0,
            -maxrepetitions => $maxrep,
            -varbindlist    => [ map { $cur{$_} } @fields ],
        );
        return undef unless defined($r) && ref($r) eq 'HASH';   # error -> fall back

        my %maxidx;
        for my $oid (keys %$r) {
            (my $o = $oid) =~ s/^\.//;
            for my $f (@fields) {
                my $b = $cols->{$f};
                next unless $o eq $b || index($o, "$b.") == 0;
                my $idx = substr($o, length($b) + 1);
                last unless $idx =~ /^\d+$/;        # single-integer entPhysicalIndex
                $row{$idx}{$f} = $r->{$oid};
                $maxidx{$f} = $idx if !defined($maxidx{$f}) || $idx > $maxidx{$f};
                last;
            }
        }
        # Advance each still-active column past its last-seen row; a column that
        # returned nothing under its base this round has reached the end.
        for my $f (@fields) {
            if (defined $maxidx{$f}) { $cur{$f} = "$cols->{$f}.$maxidx{$f}"; }
            else                     { $done{$f} = 1; }
        }
    }
    return \%row;
}

# GET the named ENTITY columns for the given entPhysicalIndexes and merge the
# values into %row (creating rows as needed). Batches the OIDs into get_request
# PDUs. Best-effort: a missing instance (noSuchObject/Instance/endOfMibView) or a
# whole failed batch is simply skipped, so a row keeps only the cells that exist.
# Used only on v2c/v3, where get_request returns per-varbind exceptions rather
# than failing the whole request (v1 uses the per-column get_table fallback).
sub _fetch_cells {
    my ($session, $row, $idxs, $fields) = @_;
    return unless @$idxs && @$fields;

    my $CHUNK = 40;                         # OIDs per GET
    my (@oids, %which);
    for my $i (@$idxs) {
        for my $f (@$fields) {
            my $oid = "$ENT_COL{$f}.$i";
            push @oids, $oid;
            $which{$oid} = [$i, $f];
        }
    }
    while (@oids) {
        my @batch = splice(@oids, 0, $CHUNK);
        my $r = $session->get_request(-varbindlist => \@batch);
        next unless defined($r) && ref($r) eq 'HASH';
        for my $oid (keys %$r) {
            (my $o = $oid) =~ s/^\.//;
            my $w = $which{$o} // $which{$oid} // next;
            my $v = $r->{$oid};
            next if defined($v)
                 && $v =~ /^(?:noSuch(?:Object|Instance)|endOfMibView)$/;
            $row->{ $w->[0] }{ $w->[1] } = $v;
        }
    }
}

# Does the real SNMP work against an open session. Returns the result hashref
# (headline + components) or undef / dies on failure.
sub _collect_session {
    my ($class, $mod, $session, $tab) = @_;

    my $level = $mod->dev_option_posint($tab, 'snmp_inventory_level', 1, 0) || 1;

    # system group (best-effort): sysObjectID (vendor/model) + sysDescr (os fallback)
    # + sysName/sysLocation/sysContact (device-level admin headline, all one GET).
    my $sys = $session->get_request(-varbindlist =>
        [$OID_sysObjectID, $OID_sysDescr, $OID_sysName, $OID_sysLocation, $OID_sysContact]);
    # Fail fast: if the agent does not even answer the system group (wrong
    # community, SNMP disabled or filtered, or host unreachable), every later
    # ENTITY request would time out too -- a dozen of them at
    # snmp_timeout*(snmp_retries+1) each, ~120s with the defaults. One unanswered
    # probe is enough to know the agent is not usable, so stop now (one timeout)
    # rather than walking the whole table and falling back per column.
    if (!$sys) {
        my $e = $session->error;
        die "SNMP agent did not respond to the system group"
            . (defined($e) && length($e) ? " ($e)" : "")
            . "; check community/version/reachability\n";
    }
    my $sysoid   = $sys ? $sys->{$OID_sysObjectID} : undef;
    my $sysdescr = $sys ? $sys->{$OID_sysDescr}    : undef;
    $sysoid =~ s/^\.//        if defined $sysoid;
    $sysoid = undef if defined($sysoid) && $sysoid !~ /^[\d.]+$/;
    # sysName/sysLocation/sysContact: device-level admin headline, stored as-is
    # (the device's own configured values; empty/noSuch -> undef).
    my $sysname     = _clean_scalar($sys->{$OID_sysName});
    my $syslocation = _clean_scalar($sys->{$OID_sysLocation});
    my $syscontact  = _clean_scalar($sys->{$OID_sysContact});
    my $ent_num;
    if (defined($sysoid) && $sysoid =~ /^1\.3\.6\.1\.4\.1\.(\d+)/) { $ent_num = $1; }

    # Gather the ENTITY-MIB into %row (entPhysicalIndex => {field=>val}). On a big
    # stack most rows are ports/sensors we never store, and a Comware IRF agent
    # serves its entPhysicalTable slowly, so pulling every column for every row
    # cost ~50s. Instead, on v2c/v3 we GET-BULK only the one dense column we must
    # read for all rows -- entPhysicalClass -- then GET the descriptive columns
    # (+ entPhysicalContainedIn, chasing it up to each chassis) for ONLY the rows
    # we keep. v1 has no GET-BULK, and if the class bulk walk errors we fall back
    # to a full per-column get_table walk. snmp_max_repetitions (default 25) tunes
    # the bulk size; raise it on a slow agent to cut round-trips.
    my $ver      = _norm_version(_opt($mod, $tab, 'snmp_version'));
    my $maxrep   = $mod->dev_option_posint($tab, 'snmp_max_repetitions', 25, 0) || 25;
    my $use_bulk = (!defined($ver) || $ver ne 'snmpv1');

    my %row;
    my $classed = $use_bulk
        ? _walk_entity($session, { class => $ENT_COL{class} }, $maxrep)
        : undef;
    if (defined $classed) {
        %row = %$classed;                             # idx => { class => N }

        # The parts worth storing: chassis/module/powerSupply always, and
        # transceiver only at level >= 2. Also fetch "stack" (class 11) rows: a
        # device that reports no chassis but describes itself as a stack (e.g. Zyxel
        # single-unit switches) carries its model/serial/OS there, and is promoted
        # to a chassis below. Fetch the descriptive columns plus contained_in for
        # just these rows (not the whole port/sensor tree).
        my @data_cols = qw(descr name hw_rev fw_rev sw_rev serial mfg model);
        my @keep = grep {
            my $cl = $row{$_}{class} // 0;
            $cl == 3 || $cl == 6 || $cl == 9 || $cl == 11 || ($cl == 10 && $level >= 2);
        } keys %row;
        _fetch_cells($session, \%row, \@keep, ['contained_in', @data_cols]);

        # Chase contained_in up to each kept part's chassis: pull class +
        # contained_in for any referenced ancestor we don't have yet. entity
        # trees are shallow; bound the loop and mark dead ends so we never refetch.
        for (1 .. 8) {
            my %need;
            for my $i (keys %row) {
                my $p = $row{$i}{contained_in};
                $need{$p} = 1 if defined($p) && $p =~ /^\d+$/ && $p > 0 && !exists $row{$p};
            }
            last unless %need;
            _fetch_cells($session, \%row, [keys %need], ['class', 'contained_in']);
            $row{$_} ||= {} for keys %need;           # dead-end: do not refetch
        }
    }
    else {
        # v1, or the class bulk walk failed: one get_table per column (everything).
        my @bulk = $use_bulk ? (-maxrepetitions => $maxrep) : ();
        for my $k (keys %ENT_COL) {
            my $t = $session->get_table(-baseoid => $ENT_COL{$k}, @bulk);
            if (!$t) {
                # Agent stopped answering mid-walk: don't hammer the remaining
                # columns with a full timeout each (belt-and-suspenders -- the
                # system-group probe above already fails fast on a dead agent).
                last if (defined($session->error) ? $session->error : '') =~ /No response|timeout/i;
                next;
            }
            my $b = $ENT_COL{$k};
            for my $oid (keys %$t) {
                (my $idx = $oid) =~ s/^\Q$b\E\.//;
                $row{$idx}{$k} = $t->{$oid};
            }
        }
    }

    # ENTITY-MIB absent or has no chassis: Hirschmann and many simple switches
    # answer the system group (and often a private MIB) but implement no
    # entPhysicalTable (1.3.6.1.2.1.47). The fail-fast probe above already proved
    # the agent answers, so rather than failing, record a headline from the system
    # group + vendor profile: vendor (sysObjectID enterprise), model (a profile
    # sysObjectID->model line, if one is defined), and OS (a sysDescr "Version ..."
    # parse). No components; member_count 1 (the one device). A device with real
    # ENTITY data falls through to the full derivation below.
    my @chassis_idx = sort { $a <=> $b } grep { ($row{$_}{class} // 0) == 3 } keys %row;

    # No real chassis, but the device describes itself as a "stack" (entPhysicalClass
    # 11): promote those stack entities to chassis so their model/serial/OS/hw_rev are
    # harvested by the full derivation below, instead of dropping to the headline-only
    # path. Common on single-unit switches that expose one top-level "stack" entry
    # (e.g. Zyxel), and correct for a real stack of N (N stack units -> N members). A
    # device that reports real chassis keeps them and ignores the stack entity (there
    # it is only a logical container).
    if (!@chassis_idx) {
        my @stack_idx = sort { $a <=> $b } grep { ($row{$_}{class} // 0) == 11 } keys %row;
        if (@stack_idx) {
            $row{$_}{class} = 3 for @stack_idx;   # treat the stack entity as a chassis
            @chassis_idx = @stack_idx;
        }
    }

    unless (@chassis_idx) {
        my $prof   = _load_profiles($mod, $tab);
        my $vendor = _vendor_for($prof, $sysoid, $ent_num);
        my $h = {
            vendor         => defined($vendor) ? $vendor : 'unknown',
            vendor_raw     => undef,
            model          => _model_for($prof, $sysoid),   # profile sysObjectID->model line, if any
            serial         => undef,
            os_version     => undef,
            sysname        => $sysname,
            syslocation    => $syslocation,
            syscontact     => $syscontact,
            member_count   => 1,
            member_serials => '',
            hw_set         => '',
            components     => [],
        };
        # An "override" directive applies on this ENTITY-less path too: the model/
        # serial/OS may live in sysDescr or a vendor OID (e.g. Aruba WLAN, whose model
        # is the sysDescr "(MODEL: nnn)" token). Consulted first, so it wins over a
        # profile model line; a numeric-OID source may name a table column (walked by
        # _get_instance). The ent* sources are empty here (no ENTITY-MIB).
        my %ovsrc = (sysdescr => $sysdescr);
        for my $f (qw(model serial os_version)) {
            my $ov = $class->_override_value($prof, $f, $sysoid, $ent_num, \%ovsrc, $session);
            $h->{$f} = $ov if defined $ov;
        }
        # Fill still-empty model/serial/os_version from the vendor's private MIB ("oid"
        # profile entries), then fall back to the sysDescr heuristic for os_version.
        $class->_apply_override_oids($session, $prof, $sysoid, $ent_num, $h);
        $h->{os_version} = _os_from_sysdescr($sysdescr) unless defined $h->{os_version};

        # A vendor "members" table (e.g. an Aruba virtual controller listing its member
        # APs in AI-AP-MIB aiAPTable): record one chassis member per row, like a stack,
        # so every member's serial/model/name is captured. Primary = the row whose name
        # matches this device's sysName (the VC's own AP), else the first member; the
        # headline serial is the primary's.
        if (my $mspec = _members_for($prof, $sysoid, $ent_num)) {
            my @mem = $class->_collect_members($session, $mspec);
            if (@mem) {
                my ($prim) = grep { defined($_->{comp_position}) && defined($sysname)
                                    && $_->{comp_position} eq $sysname } @mem;
                $prim ||= $mem[0];
                $prim->{is_primary} = 1;
                $h->{serial}         = $prim->{serial};
                $h->{member_count}   = scalar @mem;
                $h->{components}     = \@mem;
                $h->{member_serials} = join(', ', map {
                    join(':', $_->{member_index}, ($_->{model} // ''), $_->{serial})
                } @mem);
                $h->{hw_set}         = hw_set(\@mem);
            }
        }
        return $h;
    }

    my %member_of;                      # chassis entPhysicalIndex -> member number
    my $mn = 0;
    $member_of{$_} = ++$mn for @chassis_idx;

    # Resolve a component's owning chassis member by walking contained_in up.
    my $member_for = sub {
        my ($idx) = @_;
        my %seen;
        while (defined($idx) && !$seen{$idx}++) {
            return $member_of{$idx} if exists $member_of{$idx};
            $idx = $row{$idx}{contained_in};
            last unless defined($idx) && $idx =~ /^\d+$/ && $idx > 0;
        }
        return undef;
    };

    # Components: stored classes only, serial required. Dedup by (class,serial)
    # so the stack pseudo-entity, a cable's two ends, and a VSF's cross-listed
    # modules collapse to one physical part.
    my @components;
    my %seen_cs;
    my $primary_idx = $chassis_idx[0];

    for my $idx (sort { $a <=> $b } keys %row) {
        my $cls = $row{$idx}{class} // 0;
        my $comp_class = $CLASS_NAME{$cls} or next;
        next if $comp_class eq 'transceiver' && $level < 2;

        my $serial = _trim($row{$idx}{serial});
        next unless defined $serial;                       # serial-bearing only

        my $key = "$comp_class\x00$serial";
        next if $seen_cs{$key}++;                          # dedup redundant listings

        push @components, {
            member_index => $member_for->($idx),
            comp_class   => $comp_class,
            comp_position=> _trim($row{$idx}{name}) // _trim($row{$idx}{descr}),
            model        => _trim($row{$idx}{model}),
            serial       => $serial,
            sw_version   => _trim($row{$idx}{sw_rev}),
            fw_version   => _fw_clean($row{$idx}{fw_rev}),  # ROMMON/firmware (entPhysicalFirmwareRev); undef if empty or a stub (e.g. Cisco "0.1")
            hw_rev       => _trim($row{$idx}{hw_rev}),
            is_primary   => ($cls == 3 && $idx == $primary_idx) ? 1 : 0,
        };
    }

    # Headline, from the primary chassis.
    my $prof = _load_profiles($mod, $tab);
    my $p = \%{ $row{$primary_idx} };
    my $vendor_raw = _trim($p->{mfg});
    my $vendor = _vendor_for($prof, $sysoid, $ent_num) // $vendor_raw // 'unknown';

    # member_count: number of serial-bearing chassis (a stack counts its members).
    # When no chassis carries a serial (old single-chassis devices), fall back to
    # the count of physical chassis entities, so a lone serial-less chassis is 1.
    my @chassis_rows = grep { $_->{comp_class} eq 'chassis' } @components;
    my $member_count = @chassis_rows ? scalar(@chassis_rows) : scalar(@chassis_idx);

    # member_serials: "idx:model:serial, ..." sorted by member_index, for display.
    my @ms = sort { ($a->{member_index}//0) <=> ($b->{member_index}//0) } @chassis_rows;
    my $member_serials = join(', ', map {
        join(':', ($_->{member_index} // '?'), ($_->{model} // ''), $_->{serial})
    } @ms);

    # Profile "override" (replace a present-but-wrong ENTITY value, e.g. a chipset
    # codename in entPhysicalModelName): consulted BEFORE the ENTITY value, kept only
    # when it yields something (a regex miss falls through to the ENTITY value).
    my %src = (
        sysdescr  => $sysdescr,
        entdescr  => $p->{descr},
        entmodel  => $p->{model},
        entserial => $p->{serial},
    );
    my $model = $class->_override_value($prof, 'model', $sysoid, $ent_num, \%src, $session)
             // _trim($p->{model}) // _trim($p->{descr}) // _model_for($prof, $sysoid);
    my $serial = $class->_override_value($prof, 'serial', $sysoid, $ent_num, \%src, $session)
             // _trim($p->{serial});
    my $os = $class->_override_value($prof, 'os_version', $sysoid, $ent_num, \%src, $session)
             // _trim($p->{sw_rev}) // _fw_clean($p->{fw_rev}) // _os_from_sysdescr($sysdescr);

    return {
        vendor         => $vendor,
        vendor_raw     => $vendor_raw,
        model          => $model,
        serial         => $serial,
        os_version     => $os,
        sysname        => $sysname,
        syslocation    => $syslocation,
        syscontact     => $syscontact,
        member_count   => $member_count,
        member_serials => $member_serials,
        hw_set         => hw_set(\@components),
        components     => \@components,
    };
}

# Canonical tracked-set token: "class:serial" for chassis/module/powerSupply
# (transceivers excluded), trimmed, de-duplicated, sorted ASCII-ascending,
# joined with ", ". Must match the DB contract (fetchconfig-inventory-db-schema).
sub hw_set {
    my ($components) = @_;
    my %seen;
    my @parts;
    for my $c (@$components) {
        next unless $c->{comp_class} eq 'chassis'
                 || $c->{comp_class} eq 'module'
                 || $c->{comp_class} eq 'powerSupply';
        next unless defined $c->{serial} && length $c->{serial};
        my $tok = "$c->{comp_class}:$c->{serial}";
        push @parts, $tok unless $seen{$tok}++;
    }
    return join(', ', sort @parts);
}

1;

#!/usr/bin/perl
#
# 57-snmp-inventory.t - fetchconfig 9.80 SNMP device inventory + pw: aliases:
#   - fetchconfig::SNMPInventory: mode() enable/disable/none rule; hw_set()
#     canonicalisation; open_snmp_session() builds the right Net::SNMP params for
#     v1/v2c/v3; collect() derives headline + components from a mock ENTITY-MIB
#     (2-chassis stack), honouring snmp_inventory_level.
#   - fetchconfig::History inventory ops: op=inv_current (drain-derived upsert +
#     initial history row), op=inv_reset (component delete), op=inv_component
#     (insert); all skipped when the inventory tables are absent (pre-check gate);
#     op=rename extends to the three inventory tables when present.
#   - pw: credential aliases (when Detector/Abstract are loadable): parse,
#     lookup, and read-time resolution (kind-scoping, undefined -> undef).
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

require_ok('fetchconfig::SNMPInventory');
require_ok('fetchconfig::History');

# --- a minimal model stand-in (dev_option family + log_error) ----------------
{
    package FakeMod;
    sub new { my ($c, %o) = @_; bless { errors => [] }, $c }
    sub dev_option { my ($s, $tab, $n) = @_; return $tab->{$n}; }
    sub dev_option_posint {
        my ($s, $tab, $n, $def, $az) = @_;
        my $v = $tab->{$n};
        return $def unless defined($v) && length($v);
        my $re = $az ? qr/^\d+$/ : qr/^[1-9]\d*$/;
        return ($v =~ $re) ? $v + 0 : $def;
    }
    sub dev_option_flag {
        my ($s, $tab, $n, $def) = @_;
        my $v = $tab->{$n};
        return ($def ? 1 : 0) unless defined $v;
        return (lc($v) eq 'on' || $v eq '1') ? 1 : 0;
    }
    sub log_error { push @{ $_[0]{errors} }, $_[1]; }
}

my $mod = FakeMod->new;

# --- mode(): enable/disable/none --------------------------------------------
is(fetchconfig::SNMPInventory->mode($mod, {}), 'none',
   'mode none when no snmp_* at all');
is(fetchconfig::SNMPInventory->mode($mod, { snmp_community => 'public' }), 'on',
   'mode on with a v2c community');
is(fetchconfig::SNMPInventory->mode($mod, { snmp_community => 'public', snmp_inventory => '0' }), 'off',
   'mode off when snmp_inventory=0 overrides an inherited community');
is(fetchconfig::SNMPInventory->mode($mod, { snmp_inventory => '0' }), 'off',
   'mode off when explicitly disabled but no creds');
is(fetchconfig::SNMPInventory->mode($mod, { snmp_version => '3', snmp_user => 'u' }), 'on',
   'mode on with a v3 user');
is(fetchconfig::SNMPInventory->mode($mod, { snmp_version => '3' }), 'none',
   'mode none for v3 without a user (nothing configured)');
is(fetchconfig::SNMPInventory->mode($mod, { snmp_write_community => 'rw' }), 'on',
   'mode on with only a v2c read-WRITE community (procurve-snmp case)');
is(fetchconfig::SNMPInventory->mode($mod, { snmp_community => 'public', snmp_inventory => '1' }), 'on',
   'mode on with snmp_inventory=1 (numeric true, not just "on")');
is(fetchconfig::SNMPInventory->mode($mod, { snmp_community => 'public', snmp_inventory => 'off' }), 'off',
   'mode off with snmp_inventory=off');

# --- flag(): permissive boolean for the snmp_* flags -------------------------
is(fetchconfig::SNMPInventory->flag($mod, { x => '1' },    'x', 0), 1, 'flag: 1 -> true');
is(fetchconfig::SNMPInventory->flag($mod, { x => 'on' },   'x', 0), 1, 'flag: on -> true');
is(fetchconfig::SNMPInventory->flag($mod, { x => 'yes' },  'x', 0), 1, 'flag: yes -> true');
is(fetchconfig::SNMPInventory->flag($mod, { x => '0' },    'x', 1), 0, 'flag: 0 -> false');
is(fetchconfig::SNMPInventory->flag($mod, { x => 'off' },  'x', 1), 0, 'flag: off -> false');
is(fetchconfig::SNMPInventory->flag($mod, {},              'x', 1), 1, 'flag: unset -> default (on)');
is(fetchconfig::SNMPInventory->flag($mod, {},              'x', 0), 0, 'flag: unset -> default (off)');

# --- hw_set(): canonical tracked-set token -----------------------------------
{
    my @comp = (
        { comp_class => 'chassis',     serial => 'B2' },
        { comp_class => 'chassis',     serial => 'A1' },
        { comp_class => 'powerSupply', serial => 'P9' },
        { comp_class => 'transceiver', serial => 'SFP1' },   # excluded
        { comp_class => 'chassis',     serial => 'A1' },      # dup
    );
    is(fetchconfig::SNMPInventory::hw_set(\@comp),
       'chassis:A1, chassis:B2, powerSupply:P9',
       'hw_set: trimmed, deduped, sorted, transceivers excluded');
}

# --- open_snmp_session(): parameter mapping ----------------------------------
{
    my @cap;
    no warnings 'redefine';
    local *Net::SNMP::session = sub { shift; push @cap, { @_ }; return (bless({}, 'FakeSess'), undef); };

    fetchconfig::SNMPInventory->open_snmp_session($mod, 'h1',
        { snmp_community => 'public' });
    is($cap[-1]{'-version'}, 'snmpv2c', 'v2c default version');
    is($cap[-1]{'-community'}, 'public', 'community passed');
    is($cap[-1]{'-port'}, 161, 'default port 161');
    is($cap[-1]{'-retries'}, 1, 'default retries 1');

    fetchconfig::SNMPInventory->open_snmp_session($mod, 'h1',
        { snmp_version => '1', snmp_community => 'c1' });
    is($cap[-1]{'-version'}, 'snmpv1', 'v1 version normalised');

    # Read session with only a read-WRITE community falls back to it.
    fetchconfig::SNMPInventory->open_snmp_session($mod, 'h1',
        { snmp_write_community => 'rwonly' });
    is($cap[-1]{'-community'}, 'rwonly',
       'read session uses snmp_write_community when snmp_community is unset');

    fetchconfig::SNMPInventory->open_snmp_session($mod, 'h1', {
        snmp_version => '3', snmp_user => 'bob',
        snmp_authpass => 'apass', snmp_privpass => 'ppass',
        snmp_authproto => 'sha', snmp_privproto => 'aes',
    });
    is($cap[-1]{'-version'}, 'snmpv3', 'v3 version');
    is($cap[-1]{'-username'}, 'bob', 'v3 username');
    is($cap[-1]{'-authpassword'}, 'apass', 'v3 authpassword (authPriv derived)');
    is($cap[-1]{'-privpassword'}, 'ppass', 'v3 privpassword (authPriv derived)');

    fetchconfig::SNMPInventory->open_snmp_session($mod, 'h1', {
        snmp_version => '3', snmp_user => 'bob', snmp_authpass => 'apass',
    });
    ok(exists $cap[-1]{'-authpassword'} && !exists $cap[-1]{'-privpassword'},
       'v3 authNoPriv derived (auth only, no priv)');
}

# open_snmp_session disables OCTET STRING hex translation, so a string field with a
# non-printable/UTF-8 byte (e.g. a sysName or AP name with an umlaut) comes through as
# text rather than Net::SNMP's "0x..." hex rendering.
{
    package XlateSess;
    sub new       { my ($c, $rec) = @_; bless { rec => $rec }, $c }
    sub translate { my ($s, $arg) = @_; push @{ $s->{rec} }, $arg; return 1; }
}
{
    my @xlate;
    no warnings 'redefine';
    local *Net::SNMP::session = sub { return (XlateSess->new(\@xlate), undef); };
    fetchconfig::SNMPInventory->open_snmp_session($mod, 'h1', { snmp_community => 'public' });
    is(scalar(@xlate), 1, 'open_snmp_session sets translate once');
    is_deeply($xlate[0], ['-octetstring', 0],
        'open_snmp_session disables OCTET STRING hex translation');
}

# --- collect(): ENTITY-MIB derivation against a mock session -----------------
{
    package MockSnmp;
    my $ENT = '1.3.6.1.2.1.47.1.1.1.1';
    my %c = (descr=>2, contained_in=>4, class=>5, name=>7, hw_rev=>8,
             fw_rev=>9, sw_rev=>10, serial=>11, mfg=>12, model=>13);
    # idx => [class, name, model, serial, sw_rev, contained_in, fw_rev]
    my %dev = (
        1  => [3, 'Switch 1', 'C9300-48T', 'FVH2850L8NJ', 'Dublin 17.12.04', 0, '17.8.01r'],
        2  => [3, 'Switch 2', 'C9300-48T', 'FVH2850L8NT', 'Dublin 17.12.04', 0, '17.8.01r'],
        11 => [6, 'PS1', 'PWR-C1', 'DCC1', undef, 1, undef],
        12 => [6, 'PS2', 'PWR-C1', 'DCC2', undef, 2, undef],
        20 => [10, 'Te1/1/1', 'SFP-10G-SR', 'JUR1', undef, 1, undef],
    );
    my @map = ('class', 'name', 'model', 'serial', 'sw_rev', 'contained_in', 'fw_rev');
    my %field_pos = (class=>0, name=>1, model=>2, serial=>3, sw_rev=>4, contained_in=>5, fw_rev=>6);
    our @gt_calls;   # records get_table / get_bulk_request args (GET-BULK check)
    our @gr_oids;    # records every OID asked for via get_request (targeting check)
    sub new { bless {}, shift }
    sub get_request {
        my ($s, %a) = @_;
        push @gr_oids, @{ $a{-varbindlist} };
        my %r;
        for my $oid (@{ $a{-varbindlist} }) {
            if ($oid eq '1.3.6.1.2.1.1.2.0') { $r{$oid} = '1.3.6.1.4.1.9.1.2494'; next; }
            if ($oid eq '1.3.6.1.2.1.1.1.0') { $r{$oid} = 'Cisco IOS Software';    next; }
            my $v = _val($oid);
            $r{$oid} = defined($v) ? $v : 'noSuchInstance';
        }
        return %r ? \%r : undef;
    }
    sub get_table {
        my ($s, %a) = @_;
        push @gt_calls, { %a };
        my $base = $a{-baseoid};
        my ($field) = grep { "$ENT.$c{$_}" eq $base } keys %c;
        return undef unless defined $field;
        my $pos = $field_pos{$field};
        return undef unless defined $pos;   # columns our tiny fixture doesn't carry
        my %t;
        for my $idx (keys %dev) {
            my $v = $dev{$idx}[$pos];
            $t{"$base.$idx"} = $v if defined $v;
        }
        return %t ? \%t : undef;
    }
    # SNMP-numeric OID comparison (sub-identifier by sub-identifier).
    sub _oidcmp {
        my @a = split /\./, $_[0];
        my @b = split /\./, $_[1];
        for my $i (0 .. ($#a < $#b ? $#a : $#b)) {
            my $c = $a[$i] <=> $b[$i];
            return $c if $c;
        }
        return $#a <=> $#b;
    }
    # Every OID this mock serves, in SNMP order, with a value lookup.
    sub _all_oids {
        my @o;
        for my $f (keys %c) {
            my $pos = $field_pos{$f};
            next unless defined $pos;
            for my $idx (keys %dev) {
                push @o, "$ENT.$c{$f}.$idx" if defined $dev{$idx}[$pos];
            }
        }
        return sort { _oidcmp($a, $b) } @o;
    }
    sub _val {
        my ($oid) = @_;
        for my $f (keys %c) {
            my $b = "$ENT.$c{$f}";
            next unless index($oid, "$b.") == 0;
            my $idx = substr($oid, length($b) + 1);
            my $pos = $field_pos{$f};
            return (defined $pos && exists $dev{$idx}) ? $dev{$idx}[$pos] : undef;
        }
        return undef;
    }
    # Faithful GET-BULK: per repeater varbind, up to maxrep successive GET-NEXTs
    # over the whole mock OID space (so a column that runs off its end overshoots
    # into the next, exactly as a real agent does).
    sub get_bulk_request {
        my ($s, %a) = @_;
        push @gt_calls, { %a };
        my $maxrep = $a{'-maxrepetitions'} || 10;
        my @all = _all_oids();
        my %resp;
        for my $start (@{ $a{-varbindlist} }) {
            my $cur = $start;
            for (1 .. $maxrep) {
                my $nxt;
                for my $o (@all) { if (_oidcmp($o, $cur) > 0) { $nxt = $o; last; } }
                last unless defined $nxt;
                $resp{$nxt} = _val($nxt);
                $cur = $nxt;
            }
        }
        return %resp ? \%resp : undef;
    }
    sub close { 1 }
    sub error { '' }
}

{
    no warnings 'redefine';
    local *Net::SNMP::session = sub { return (MockSnmp->new, undef); };

    @MockSnmp::gr_oids = ();
    my $res = fetchconfig::SNMPInventory->collect($mod, 'gpnxsw0001', 'host',
        { snmp_community => 'public' });   # level 1 default
    is($res->{status}, 'successful', 'collect: successful');
    is($res->{vendor}, 'Cisco', 'vendor via sysObjectID enterprise 9');
    is($res->{model}, 'C9300-48T', 'primary chassis model');
    is($res->{serial}, 'FVH2850L8NJ', 'primary chassis serial');
    is($res->{os_version}, 'Dublin 17.12.04', 'os_version from softwareRev');
    is($res->{member_count}, 2, 'two stack members');
    is($res->{hw_set},
       'chassis:FVH2850L8NJ, chassis:FVH2850L8NT, powerSupply:DCC1, powerSupply:DCC2',
       'hw_set over chassis + PSUs (no transceiver)');
    is($res->{member_serials},
       '1:C9300-48T:FVH2850L8NJ, 2:C9300-48T:FVH2850L8NT',
       'member_serials for display');
    is(scalar(@{ $res->{components} }), 4,
       'level 1: 2 chassis + 2 PSU, transceiver excluded');
    my ($prim) = grep { $_->{is_primary} } @{ $res->{components} };
    is($prim->{serial}, 'FVH2850L8NJ', 'first chassis marked primary');
    is($prim->{fw_version}, '17.8.01r',
       'component carries fw_version (ROMMON) from entPhysicalFirmwareRev');
    my ($ps) = grep { $_->{comp_class} eq 'powerSupply' } @{ $res->{components} };
    ok(!defined($ps->{fw_version}),
       'component fw_version left undef when entPhysicalFirmwareRev is empty');

    # Targeting: at level 1 the excluded transceiver (idx 20, class 10) is NOT
    # queried for its data columns -- only entPhysicalClass is read for it.
    my $xcvr_serial_oid = '1.3.6.1.2.1.47.1.1.1.1.11.20';   # serial col, idx 20
    ok(!(grep { $_ eq $xcvr_serial_oid } @MockSnmp::gr_oids),
       'level 1: no data GET for the excluded transceiver (only its class is walked)');

    @MockSnmp::gr_oids = ();
    my $res2 = fetchconfig::SNMPInventory->collect($mod, 'gpnxsw0001', 'host',
        { snmp_community => 'public', snmp_inventory_level => '2' });
    is(scalar(@{ $res2->{components} }), 5,
       'level 2: transceiver included');
    ok((grep { $_->{comp_class} eq 'transceiver' } @{ $res2->{components} }),
       'level 2 has a transceiver row');
    ok((grep { $_ eq $xcvr_serial_oid } @MockSnmp::gr_oids),
       'level 2: the transceiver IS fetched (its serial is queried)');

    # GET-BULK: v2c passes -maxrepetitions to get_table (so a big stack is a few
    # PDUs, not one GET-NEXT per row per column); v1 must not.
    @MockSnmp::gt_calls = ();
    fetchconfig::SNMPInventory->collect($mod, 'x', 'host', { snmp_community => 'public' });
    ok((grep { exists $_->{'-maxrepetitions'} } @MockSnmp::gt_calls),
       'v2c: ENTITY walk uses GET-BULK (-maxrepetitions)');
    @MockSnmp::gt_calls = ();
    fetchconfig::SNMPInventory->collect($mod, 'x', 'host',
        { snmp_community => 'public', snmp_version => '1' });
    ok(!(grep { exists $_->{'-maxrepetitions'} } @MockSnmp::gt_calls),
       'v1: no GET-BULK (get_table GET-NEXT, no -maxrepetitions)');
}

# Fail-fast: a dead / wrong-community agent (no response to the system group) must
# give up after the single probe -- NOT walk the whole ENTITY-MIB and then fall
# back per column, which would be ~a dozen full timeouts (~120s with the defaults).
{
    package MockDead;
    our $walked = 0;
    sub new { bless {}, shift }
    sub get_request      { return undef; }               # agent never answers
    sub get_bulk_request { $walked++; return undef; }
    sub get_table        { $walked++; return undef; }
    sub error            { 'No response from remote host' }
    sub close            { }
}
{
    no warnings 'redefine';
    local *Net::SNMP::session = sub { return (MockDead->new, undef); };
    $MockDead::walked = 0;
    my $res = fetchconfig::SNMPInventory->collect($mod, 'dead', 'host',
        { snmp_community => 'public' });
    is($res->{status}, 'failed', 'fail-fast: unreachable agent -> failed');
    like($res->{error}, qr/did not respond/,
         'fail-fast: error says the agent did not respond');
    is($MockDead::walked, 0,
       'fail-fast: no ENTITY walk or per-column fallback after the probe times out');
}

# --- collect(): old HP 4000M - serial-less single chassis, no ENTITY swRev ----
# ENTITY-MIB has one chassis with a descr but no model, no serial and no swRev;
# sysDescr carries the firmware ("revision C.09.30"). Exercises the three 9.80
# fallbacks: member_count from the physical chassis, os_version from sysDescr,
# and (not hit here, descr present) the sysObjectID->model lookup.
{
    package MockSnmp4000;
    my $ENT = '1.3.6.1.2.1.47.1.1.1.1';
    my %c = (descr=>2, contained_in=>4, class=>5, name=>7, hw_rev=>8,
             fw_rev=>9, sw_rev=>10, serial=>11, mfg=>12, model=>13);
    # idx => [class, name, model, serial, sw_rev, contained_in, descr]
    my %dev = (
        1 => [3, 'Chassis', undef, undef, undef, 0, 'HP J4121A ProCurve Switch 4000M'],
    );
    my %field_pos = (class=>0, name=>1, model=>2, serial=>3, sw_rev=>4,
                     contained_in=>5, descr=>6);
    sub new { bless {}, shift }
    sub get_request {
        my ($s, %a) = @_;
        my %r;
        for my $oid (@{ $a{-varbindlist} }) {
            if ($oid eq '1.3.6.1.2.1.1.2.0') { $r{$oid} = '1.3.6.1.4.1.11.2.3.7.11.9'; next; }
            if ($oid eq '1.3.6.1.2.1.1.1.0') {
                $r{$oid} = 'HP J4121A ProCurve Switch 4000M, revision C.09.30, ROM C.06.01 (/sw/code)';
                next;
            }
            if ($oid eq '1.3.6.1.2.1.1.5.0') { $r{$oid} = 'core-sw-01';   next; }  # sysName
            if ($oid eq '1.3.6.1.2.1.1.6.0') { $r{$oid} = 'MDF rack 3';   next; }  # sysLocation
            if ($oid eq '1.3.6.1.2.1.1.4.0') { $r{$oid} = 'netops';       next; }  # sysContact
            my $v;
            for my $f (keys %c) {
                my $b = "$ENT.$c{$f}";
                next unless index($oid, "$b.") == 0;
                my $idx = substr($oid, length($b) + 1);
                my $pos = $field_pos{$f};
                $v = (defined $pos && exists $dev{$idx}) ? $dev{$idx}[$pos] : undef;
                last;
            }
            $r{$oid} = defined($v) ? $v : 'noSuchInstance';
        }
        return %r ? \%r : undef;
    }
    sub get_table {
        my ($s, %a) = @_;
        my $base = $a{-baseoid};
        my ($field) = grep { "$ENT.$c{$_}" eq $base } keys %c;
        return undef unless defined $field;
        my $pos = $field_pos{$field};
        return undef unless defined $pos;
        my %t;
        for my $idx (keys %dev) {
            my $v = $dev{$idx}[$pos];
            $t{"$base.$idx"} = $v if defined $v;
        }
        return %t ? \%t : undef;
    }
    sub _oidcmp {
        my @a = split /\./, $_[0]; my @b = split /\./, $_[1];
        for my $i (0 .. ($#a < $#b ? $#a : $#b)) { my $c = $a[$i] <=> $b[$i]; return $c if $c; }
        return $#a <=> $#b;
    }
    sub get_bulk_request {
        my ($s, %a) = @_;
        my $maxrep = $a{'-maxrepetitions'} || 10;
        my @all;
        for my $f (keys %c) {
            my $pos = $field_pos{$f}; next unless defined $pos;
            for my $idx (keys %dev) { push @all, "$ENT.$c{$f}.$idx" if defined $dev{$idx}[$pos]; }
        }
        @all = sort { _oidcmp($a, $b) } @all;
        my $val = sub {
            my ($oid) = @_;
            for my $f (keys %c) { my $b = "$ENT.$c{$f}";
                next unless index($oid, "$b.") == 0;
                my $idx = substr($oid, length($b)+1); my $pos = $field_pos{$f};
                return (defined $pos && exists $dev{$idx}) ? $dev{$idx}[$pos] : undef; }
            undef;
        };
        my %resp;
        for my $start (@{ $a{-varbindlist} }) {
            my $cur = $start;
            for (1 .. $maxrep) {
                my $nxt; for my $o (@all) { if (_oidcmp($o, $cur) > 0) { $nxt = $o; last; } }
                last unless defined $nxt;
                $resp{$nxt} = $val->($nxt); $cur = $nxt;
            }
        }
        return %resp ? \%resp : undef;
    }
    sub close { 1 }
    sub error { '' }
}

{
    no warnings 'redefine';
    local *Net::SNMP::session = sub { return (MockSnmp4000->new, undef); };

    my $res = fetchconfig::SNMPInventory->collect($mod, 'swi077b1', 'host',
        { snmp_community => 'public' });
    is($res->{status}, 'successful', '4000M: successful even with no serial');
    is($res->{vendor}, 'HP', '4000M: vendor HP via enterprise 11');
    is($res->{model}, 'HP J4121A ProCurve Switch 4000M', '4000M: model from ENTITY descr');
    ok(!defined($res->{serial}) || $res->{serial} eq '', '4000M: no serial');
    is($res->{os_version}, 'C.09.30', '4000M: os_version from sysDescr fallback');
    is($res->{sysname},     'core-sw-01', '4000M: sysName captured (full-ENTITY path)');
    is($res->{syslocation}, 'MDF rack 3', '4000M: sysLocation captured (full-ENTITY path)');
    is($res->{syscontact},  'netops',     '4000M: sysContact captured (full-ENTITY path)');
    is($res->{member_count}, 1, '4000M: member_count 1 from the physical chassis');
    is(scalar(@{ $res->{components} }), 0, '4000M: no serial-bearing components');
    is($res->{hw_set}, '', '4000M: empty hw_set (nothing with a serial)');
}

# --- collect(): ENTITY-less device -> headline fallback (9.80) ----------------
# Hirschmann classic switches answer the system group but implement no
# entPhysicalTable. The fail-fast probe proves the agent is alive, so instead of
# failing collect() records a one-device headline (vendor from the sysObjectID
# enterprise, no components). enterprise 248 is a built-in vendor, so this does
# not depend on the shipped profiles file.
{
    package MockHirsch;
    sub new { bless {}, shift }
    sub get_request {
        my ($s, %a) = @_;
        my %sys = (
            '1.3.6.1.2.1.1.2.0' => '1.3.6.1.4.1.248.14.10.40',   # sysObjectID (ent 248)
            '1.3.6.1.2.1.1.1.0' => 'Hirschmann Railswitch',       # sysDescr (no version token)
            '1.3.6.1.2.1.1.5.0' => 'U-5141-SW1',                  # sysName
            '1.3.6.1.2.1.1.6.0' => 'Meistercontainer_511',        # sysLocation
            '1.3.6.1.2.1.1.4.0' => 'IT',                           # sysContact
        );
        my %r;
        $r{$_} = $sys{$_} for grep { exists $sys{$_} } @{ $a{-varbindlist} };
        return %r ? \%r : undef;     # no ENTITY / private OID answers
    }
    sub get_bulk_request { return {}; }    # defined-but-empty: no entPhysical rows
    sub get_table        { return {}; }
    sub error            { '' }
    sub close            { }
}
{
    no warnings 'redefine';
    local *Net::SNMP::session = sub { return (MockHirsch->new, undef); };
    my $res = fetchconfig::SNMPInventory->collect($mod, 'hirsch1', 'host',
        { snmp_community => 'public' });
    is($res->{status}, 'successful',
       'headline: ENTITY-less agent that answers the system group is NOT failed');
    is($res->{vendor}, 'Hirschmann (Belden)',
       'headline: vendor from the sysObjectID enterprise (248 built-in)');
    is($res->{member_count}, 1, 'headline: member_count 1 (the one device)');
    is(scalar(@{ $res->{components} }), 0, 'headline: no components');
    is($res->{sysname},     'U-5141-SW1',           'headline: sysName captured');
    is($res->{syslocation}, 'Meistercontainer_511', 'headline: sysLocation captured');
    is($res->{syscontact},  'IT',                   'headline: sysContact captured');
}

# --- override OIDs: _override_oid + _apply_override_oids (9.80) ----------------
# A profile "oid" entry reads a headline field from a vendor PRIVATE MIB when the
# ENTITY-MIB is absent. Tested with a hand-built profile + mock session so it does
# not depend on the shipped profiles file (which prove would not find anyway).
{
    my $prof = {
        oid => {
            model      => { sysoid => [], ent => { 248 => ['1.3.6.1.4.1.248.14.1.1.9.1.3.1', undef] } },
            os_version => { sysoid => [], ent => { 248 => ['1.3.6.1.4.1.248.14.1.1.2.0', 'SW:\s*(\S+)'] } },
            serial     => { sysoid => [], ent => { 248 => ['1.3.6.1.4.1.248.14.1.1.9.1.10.1', undef] } },
        },
    };

    # _override_oid resolves by enterprise number and returns [oid, regex].
    my $spec = fetchconfig::SNMPInventory::_override_oid($prof, 'os_version', undef, 248);
    is($spec->[0], '1.3.6.1.4.1.248.14.1.1.2.0', '_override_oid: enterprise match -> OID');
    is($spec->[1], 'SW:\s*(\S+)',                 '_override_oid: carries the regex');
    ok(!defined fetchconfig::SNMPInventory::_override_oid($prof, 'model', undef, 11),
       '_override_oid: no entry for a different enterprise -> undef');

    package MockOidSess;
    our %V = (
        '1.3.6.1.4.1.248.14.1.1.9.1.3.1'  => 'RS20-0400M2T1SDAEHH',
        '1.3.6.1.4.1.248.14.1.1.2.0'      => 'SW: L2E-06.0.03 CH: 1.20 BP: 202',
        '1.3.6.1.4.1.248.14.1.1.9.1.10.1' => '943434009214703916',
    );
    sub new { bless {}, shift }
    sub get_request {
        my ($s, %a) = @_;
        my ($oid) = @{ $a{-varbindlist} };
        return exists $V{$oid} ? { $oid => $V{$oid} } : { $oid => 'noSuchObject' };
    }
    package main;

    my $h = { model => undef, serial => undef, os_version => undef };
    fetchconfig::SNMPInventory->_apply_override_oids(
        MockOidSess->new, $prof, '1.3.6.1.4.1.248.14.10.40', 248, $h);
    is($h->{model},      'RS20-0400M2T1SDAEHH', 'override: model from the private OID');
    is($h->{os_version}, 'L2E-06.0.03',         'override: os_version via SW:\s*(\S+) capture');
    is($h->{serial},     '943434009214703916',  'override: serial from the private OID');

    # fill-if-empty: an already-set field is never second-guessed.
    my $h2 = { model => 'FROM-ENTITY', serial => undef, os_version => undef };
    fetchconfig::SNMPInventory->_apply_override_oids(
        MockOidSess->new, $prof, '1.3.6.1.4.1.248.14.10.40', 248, $h2);
    is($h2->{model}, 'FROM-ENTITY', 'override: does not overwrite a field already set');

    # a field with no matching profile entry stays undef (noSuchObject skipped).
    my $prof_hw = { oid => { model => { sysoid => [], ent => {} } } };
    my $h3 = { model => undef };
    fetchconfig::SNMPInventory->_apply_override_oids(
        MockOidSess->new, $prof_hw, '1.3.6.1.4.1.248.14.10.40', 248, $h3);
    ok(!defined $h3->{model}, 'override: no entry -> field stays undef');
}

# --- "override" directive: _override_field + _override_value (9.80) ------------
# "override" REPLACES a present-but-wrong ENTITY value (e.g. a chipset codename a
# PLANET switch reports in entPhysicalModelName). Hand-built profile + mock sources.
{
    my $prof = {
        override => {
            model  => { sysoid => [], ent => { 10456 => ['sysdescr', '^PLANET,\s*([^,]+)'] } },
            serial => { sysoid => [], ent => { 10456 => ['entserial', 'System MAC:\s*(\S+)'] } },
        },
    };
    my %src = (
        sysdescr  => 'PLANET, IGS-5225-8P4S, IE L2+ Managed PoE+ Switch, v5.2112b240301',
        entdescr  => 'PLANET, IGS-5225-8P4S, IE L2+ Managed PoE+ Switch, v5.2112b240301',
        entmodel  => 'Luton26',
        entserial => 'System MAC: a8-f7-e0-cb-ac-68',
    );

    my $spec = fetchconfig::SNMPInventory::_override_field($prof, 'model', undef, 10456);
    is($spec->[0], 'sysdescr', '_override_field: enterprise match -> source');

    # model from sysDescr 2nd field, trimmed (this is the Luton26 -> IGS-5225 fix).
    is(fetchconfig::SNMPInventory->_override_value($prof, 'model', undef, 10456, \%src, undef),
       'IGS-5225-8P4S', 'override: model extracted from sysDescr (replaces "Luton26")');

    # serial MAC-prefix stripped via entserial source.
    is(fetchconfig::SNMPInventory->_override_value($prof, 'serial', undef, 10456, \%src, undef),
       'a8-f7-e0-cb-ac-68', 'override: serial MAC extracted from entserial');

    # no override spec for this field -> undef (keeps the ENTITY value).
    ok(!defined fetchconfig::SNMPInventory->_override_value($prof, 'os_version', undef, 10456, \%src, undef),
       'override: no spec -> undef (ENTITY value kept)');

    # a regex miss -> undef (never blanks the field).
    my $prof_miss = { override => { model => { sysoid => [], ent => { 10456 => ['sysdescr', '^NOPE,\s*(\S+)'] } } } };
    ok(!defined fetchconfig::SNMPInventory->_override_value($prof_miss, 'model', undef, 10456, \%src, undef),
       'override: regex miss -> undef (ENTITY value kept)');

    # numeric-OID source -> GET one instance.
    package MockOvSess;
    sub new { bless {}, shift }
    sub get_request { my ($s, %a) = @_; my ($o) = @{ $a{-varbindlist} };
        return { $o => ($o eq '1.3.6.1.4.1.10456.1.2.3.0' ? 'IGS-FROM-OID' : 'noSuchObject') }; }
    package main;
    my $prof_oid = { override => { model => { sysoid => [], ent => { 10456 => ['1.3.6.1.4.1.10456.1.2.3.0', undef] } } } };
    is(fetchconfig::SNMPInventory->_override_value($prof_oid, 'model', undef, 10456, \%src, MockOvSess->new),
       'IGS-FROM-OID', 'override: model from a numeric OID source');

    # sysObjectID match (most-specific) beats the enterprise tier.
    my $prof_so = { override => { model => { sysoid => [['1.3.6.1.4.1.10456.9.40', 'entmodel', undef]],
                                             ent => { 10456 => ['sysdescr', undef] } } } };
    is(fetchconfig::SNMPInventory->_override_value($prof_so, 'model', '1.3.6.1.4.1.10456.9.40', 10456, \%src, undef),
       'Luton26', 'override: sysObjectID entry wins over the enterprise entry');
}

# --- collect(): lone "stack" entity promoted to chassis (9.80) -----------------
# A device with no entPhysicalClass chassis(3) but a single stack(11) entity (e.g.
# Zyxel RGS200 single-unit switches) is promoted: the stack entity is treated as the
# chassis, so its serial/OS/hw are harvested by the full derivation instead of
# dropping to the headline-only path. 890 (Zyxel) is a built-in vendor.
{
    package MockZyStack;
    my $ENT = '1.3.6.1.2.1.47.1.1.1.1';
    my %col = (class => 5, descr => 2, serial => 11, model => 13, sw_rev => 10,
               contained_in => 4, name => 7);
    my %stack = (class => 11, descr => '', model => '', name => 'U-54311EL1-01-04-SW1',
                 serial => 'System MAC: b8-ec-a3-ff-a6-db', sw_rev => 'V1.00(ABEP.1)',
                 contained_in => 0);
    sub new { bless {}, shift }
    sub get_request {
        my ($s, %a) = @_;
        my %sys = (
            '1.3.6.1.2.1.1.2.0' => '1.3.6.1.4.1.890.1.15.5',  # sysObjectID (ent 890)
            '1.3.6.1.2.1.1.1.0' => 'RGS200-12P',               # sysDescr (bare model)
            '1.3.6.1.2.1.1.5.0' => 'U-54311EL1-01-04-SW1',
            '1.3.6.1.2.1.1.6.0' => 'SPU',
            '1.3.6.1.2.1.1.4.0' => 'Maik Thon',
        );
        my %r;
        for my $o (@{ $a{-varbindlist} }) {
            if (exists $sys{$o}) { $r{$o} = $sys{$o}; next; }
            for my $f (keys %col) { $r{$o} = $stack{$f} if $o eq "$ENT.$col{$f}.1" && defined $stack{$f}; }
        }
        return %r ? \%r : undef;
    }
    sub get_bulk_request { return { '1.3.6.1.2.1.47.1.1.1.1.5.1' => 11 }; }  # one row, class=stack
    sub get_table        { undef }
    sub error            { '' }
    sub close            { }
}
{
    no warnings 'redefine';
    local *Net::SNMP::session = sub { return (MockZyStack->new, undef); };
    my $res = fetchconfig::SNMPInventory->collect($mod, 'zy1', 'host',
        { snmp_community => 'public' });
    is($res->{status}, 'successful',   'stack: a lone stack entity is collected, not failed');
    is($res->{vendor}, 'Zyxel Communications', 'stack: vendor from the 890 built-in');
    is($res->{serial}, 'System MAC: b8-ec-a3-ff-a6-db',
       'stack: serial harvested from the promoted stack entity');
    is($res->{os_version}, 'V1.00(ABEP.1)',
       'stack: os_version harvested from the promoted stack entity sw_rev');
    is($res->{member_count}, 1, 'stack: one member');
    is(scalar(@{ $res->{components} }), 1, 'stack: the promoted stack is stored as one component');
    is($res->{components}[0]{comp_class}, 'chassis',
       'stack: promoted entity is stored as comp_class chassis (DB CHECK-safe)');
}

# --- Aruba WLAN virtual controller (ent 14823): ENTITY-less + "members" table ------
# A VC AP implements no ENTITY-MIB but lists all of its member APs in AI-AP-MIB
# aiAPTable. Vendor from built-in 14823, model from the sysDescr "(MODEL: nnn)"
# override (applied on the ENTITY-less path), OS from the "Version ..." heuristic, and
# one chassis MEMBER per member AP (serial/model/name) from the "members" directive --
# like a stack. Primary = the member whose name matches the device sysName (the VC).
{
    package MockAruba;
    my $AIAP = '1.3.6.1.4.1.14823.2.3.3.1.2.1.1';          # aiAPTable entry
    # MAC index => [serial, model, name]; .219 is the VC's own AP (name == sysName).
    my %MEM = (
        '184.236.163.255.166.219' => ['CNABC12345', 'AP-515', 'apgmg10 E3 Stern GF'],
        '100.1.2.3.4.5'           => ['CNQRS11111', 'AP-345', 'apgmg12 West'],
        '184.236.163.255.166.100' => ['CNXYZ67890', 'AP-515', 'apgmg11 E3 Nord'],
    );
    sub new { bless {}, shift }
    sub get_request {
        my ($s, %a) = @_;
        my %sys = (
            '1.3.6.1.2.1.1.2.0' => '1.3.6.1.4.1.14823.1.2.71',   # sysObjectID (ent 14823)
            '1.3.6.1.2.1.1.1.0' => 'AOS-8 (MODEL: 515), Version 8.13.3.1-8.13.3.1 LSR',
            '1.3.6.1.2.1.1.5.0' => 'apgmg10 E3 Stern GF',        # sysName
            '1.3.6.1.2.1.1.6.0' => 'Waghaeusel',                 # sysLocation
        );
        my %r;
        $r{$_} = $sys{$_} for grep { exists $sys{$_} } @{ $a{-varbindlist} };
        return %r ? \%r : undef;     # a column-base GET -> no key -> undef
    }
    sub get_next_request {           # exercises the "oid ....*" scalar column walk
        my ($s, %a) = @_;
        my %r;
        $r{"$AIAP.4.100.1.2.3.4.5"} = $MEM{'100.1.2.3.4.5'}[0]
            if grep { $_ eq "$AIAP.4" } @{ $a{-varbindlist} };
        return %r ? \%r : undef;
    }
    sub get_table {                  # the members walk: one column per -baseoid
        my ($s, %a) = @_;
        my %col = ("$AIAP.4" => 0, "$AIAP.6" => 1, "$AIAP.2" => 2);   # serial/model/name
        my $c = $col{ $a{-baseoid} // '' };
        return {} unless defined $c;
        my %r; $r{"$a{-baseoid}.$_"} = $MEM{$_}[$c] for keys %MEM;
        return \%r;
    }
    sub get_bulk_request { return {}; }    # no entPhysical rows (ENTITY-less)
    sub error            { '' }
    sub close            { }
}
{
    no warnings 'redefine';
    local *Net::SNMP::session = sub { return (MockAruba->new, undef); };
    my $AIAP = '1.3.6.1.4.1.14823.2.3.3.1.2.1.1';
    my $prof = {
        exact => {}, prefix => [], ent => { 14823 => 'Aruba Networks' },
        model_exact => {}, model_prefix => [], oid => {},
        override => { model => { sysoid => [],
                      ent => { 14823 => ['sysdescr', 'MODEL:\s*([^)]+)', 0] } } },
        members  => { sysoid => [],
                      ent => { 14823 => ["$AIAP.4", "$AIAP.6", "$AIAP.2", undef] } },
    };
    local *fetchconfig::SNMPInventory::_load_profiles = sub { $prof };
    my $res = fetchconfig::SNMPInventory->collect($mod, 'aruba1', 'host',
        { snmp_community => 'public' });
    is($res->{status},       'successful',        'Aruba VC: ENTITY-less controller collected, not failed');
    is($res->{vendor},       'Aruba Networks',    'Aruba VC: vendor from built-in 14823');
    is($res->{model},        '515',               'Aruba VC: headline model from sysDescr "(MODEL: 515)"');
    is($res->{os_version},   '8.13.3.1-8.13.3.1', 'Aruba VC: OS from the "Version ..." heuristic');
    is($res->{member_count}, 3,                   'Aruba VC: member_count = all three member APs');
    is(scalar(@{ $res->{components} }), 3,        'Aruba VC: one component per member AP');
    is((scalar grep { $_->{comp_class} eq 'chassis' } @{ $res->{components} }), 3,
       'Aruba VC: each member stored as a chassis (like a stack member)');
    my ($prim) = grep { $_->{is_primary} } @{ $res->{components} };
    is($prim->{comp_position}, 'apgmg10 E3 Stern GF',
       'Aruba VC: primary = the member whose name matches the device sysName (the VC)');
    is($res->{serial}, 'CNABC12345', 'Aruba VC: headline serial = the primary member serial');
    like($res->{hw_set}, qr/chassis:CNABC12345/, 'Aruba VC: hw_set covers the primary member');
    like($res->{hw_set}, qr/chassis:CNXYZ67890/, 'Aruba VC: hw_set covers a second member');
    like($res->{hw_set}, qr/chassis:CNQRS11111/, 'Aruba VC: hw_set covers the third member');
    like($res->{member_serials}, qr/CNABC12345/, 'Aruba VC: member_serials lists the members');

    # The ".*" single-value column walk (_get_instance) still works for the scalar case.
    my $s = MockAruba->new;
    is(fetchconfig::SNMPInventory::_get_instance($s, '1.3.6.1.2.1.1.5.0', 0),
       'apgmg10 E3 Stern GF', '_get_instance: plain GET of a scalar instance (walk off)');
    is(fetchconfig::SNMPInventory::_get_instance($s, "$AIAP.4", 1),
       'CNQRS11111', '_get_instance: walk on -> GETNEXT first row in the column');
    ok(!defined fetchconfig::SNMPInventory::_get_instance($s, "$AIAP.4", 0),
       '_get_instance: walk OFF on a column base -> undef (no auto-fallback)');

    # _walk_column returns index -> value across the whole column.
    my $w = fetchconfig::SNMPInventory::_walk_column($s, "$AIAP.4");
    is(scalar(keys %$w), 3, '_walk_column: all three rows of the serial column');
    is($w->{'100.1.2.3.4.5'}, 'CNQRS11111', '_walk_column: keyed by the per-row index suffix');
}

# --- os_version-from-sysDescr + sysObjectID->model unit tests -----------------
{
    my $o = \&fetchconfig::SNMPInventory::_os_from_sysdescr;
    is($o->('HP J4121A ProCurve Switch 4000M, revision C.09.30, ROM C.06.01'),
       'C.09.30', '_os_from_sysdescr: HP "revision" form');
    is($o->('Cisco IOS Software, C9300, Version 17.12.04, RELEASE'),
       '17.12.04', '_os_from_sysdescr: Cisco "Version" form');
    is($o->('switch with no version string here'), undef,
       '_os_from_sysdescr: nothing recognisable -> undef');
    is($o->(undef), undef, '_os_from_sysdescr: undef in -> undef');

    my $prof = fetchconfig::SNMPInventory::_load_profiles($mod, {});
    is(fetchconfig::SNMPInventory::_model_for($prof, '1.3.6.1.4.1.11.2.3.7.11.9'),
       'HP J4121A ProCurve Switch 4000M', '_model_for: built-in 4000M by sysObjectID');
    is(fetchconfig::SNMPInventory::_model_for($prof, '1.3.6.1.4.1.9.1.2494'), undef,
       '_model_for: unknown sysObjectID -> undef');
}

# --- _fw_clean(): drop entPhysicalFirmwareRev stubs (Cisco C9000 reports "0.1") --
{
    my $f = \&fetchconfig::SNMPInventory::_fw_clean;
    is($f->('17.8.01r'), '17.8.01r', '_fw_clean: real ROMMON kept');
    is($f->('  17.8.01r '), '17.8.01r', '_fw_clean: trims whitespace');
    is($f->('V05'), 'V05', '_fw_clean: real rev kept');
    is($f->('0.1'), undef, '_fw_clean: Cisco C9000 "0.1" stub -> undef');
    is($f->('0.0'), undef, '_fw_clean: "0.0" stub -> undef');
    is($f->('0'), undef, '_fw_clean: "0" stub -> undef');
    is($f->('0.0.0'), undef, '_fw_clean: all-zero dotted stub -> undef');
    is($f->('(unavailable)'), undef, '_fw_clean: "(unavailable)" -> undef');
    is($f->('N/A'), undef, '_fw_clean: "N/A" (case-insensitive) -> undef');
    is($f->(''), undef, '_fw_clean: empty -> undef');
    is($f->(undef), undef, '_fw_clean: undef in -> undef');
}

# --- History inventory ops (mock dbh) ----------------------------------------
{
    my $dbh = MockInvDbh->new(inv_present => 1);
    fetchconfig::History::_probe_inv_tables($dbh);

    # op=inv_current for a new, successful device -> INSERT + initial history row.
    my $ok = fetchconfig::History::_apply_op($dbh, {
        op => 'inv_current', dev_id => 'sw1', status => 'successful', source => 'snmp',
        run_end => 100, vendor => 'Cisco', model => 'C9300-48T', serial => 'S1',
        os_version => 'X', member_count => 1, member_serials => '1:C9300-48T:S1',
        hw_set => 'chassis:S1', history_on => 1,
    });
    is($ok, 1, 'inv_current applied');
    ok((grep { $_->{sql} =~ /INSERT INTO device_inventory\b/ } @{ $dbh->{calls} }),
       'inv_current INSERTs the headline for a new device');
    my ($h) = grep { $_->{sql} =~ /INSERT INTO device_inventory_history/ } @{ $dbh->{calls} };
    ok($h, 'inv_current inserts a history row on first sighting');
    is($h->{bind}[5], 'initial', 'history note is "initial" for the first row');

    # op=inv_reset + op=inv_component.
    $dbh = MockInvDbh->new(inv_present => 1);
    fetchconfig::History::_probe_inv_tables($dbh);
    fetchconfig::History::_apply_op($dbh, { op => 'inv_reset', dev_id => 'sw1' });
    ok((grep { $_->{sql} =~ /DELETE FROM device_inventory_component/ } @{ $dbh->{calls} }),
       'inv_reset deletes the component rows (snapshot-replace)');
    fetchconfig::History::_apply_op($dbh, {
        op => 'inv_component', dev_id => 'sw1', member_index => 1, comp_class => 'chassis',
        comp_position => 'Switch 1', model => 'C9300-48T', serial => 'S1',
        sw_version => '17.15.06', fw_version => '17.8.01r', is_primary => 1,
    });
    my ($ci) = grep { $_->{sql} =~ /INSERT INTO device_inventory_component/ } @{ $dbh->{calls} };
    ok($ci, 'inv_component inserts a part');
    # fw_version column present (2.16) -> included in the INSERT and bound.
    like($ci->{sql}, qr/\bfw_version\b/, 'inv_component INSERT includes fw_version when the column exists');
    ok((grep { defined($_) && $_ eq '17.8.01r' } @{ $ci->{bind} }),
       'inv_component binds the ROMMON/firmware value');

    # Same op against a pre-2.16 DB (column absent) -> INSERT omits fw_version.
    my $nofw = MockInvDbh->new(inv_present => 1, fw_col => 0);
    fetchconfig::History::_probe_inv_tables($nofw);
    fetchconfig::History::_apply_op($nofw, {
        op => 'inv_component', dev_id => 'sw1', member_index => 1, comp_class => 'chassis',
        comp_position => 'Switch 1', model => 'C9300-48T', serial => 'S1',
        sw_version => '17.15.06', fw_version => '17.8.01r', is_primary => 1,
    });
    my ($ci2) = grep { $_->{sql} =~ /INSERT INTO device_inventory_component/ } @{ $nofw->{calls} };
    unlike($ci2->{sql}, qr/\bfw_version\b/, 'inv_component omits fw_version when the column is absent (pre-2.16)');

    # inv_current with sys* fields: UPSERT includes the three columns when the
    # device_inventory.sysname column exists (web schema 2.17).
    $dbh = MockInvDbh->new(inv_present => 1);
    fetchconfig::History::_probe_inv_tables($dbh);
    fetchconfig::History::_apply_op($dbh, {
        op => 'inv_current', dev_id => 'sw2', status => 'successful', source => 'snmp',
        run_end => 200, vendor => 'PLANET Technology Corporation', model => 'IGS-5225-8P4S',
        serial => 'S9', os_version => 'v5', member_count => 1,
        sysname => 'U-5141-SW1', syslocation => 'Meistercontainer_511', syscontact => 'IT',
        hw_set => '', history_on => 1,
    });
    my ($iv) = grep { $_->{sql} =~ /INSERT INTO device_inventory\b/ } @{ $dbh->{calls} };
    like($iv->{sql}, qr/\bsysname\b/,     'inv_current INSERT includes sysname when the column exists (2.17)');
    like($iv->{sql}, qr/\bsyslocation\b/, 'inv_current INSERT includes syslocation (2.17)');
    ok((grep { defined($_) && $_ eq 'Meistercontainer_511' } @{ $iv->{bind} }),
       'inv_current binds the sysLocation value');

    # Same op against a pre-2.17 DB (sysname column absent) -> the three columns omitted.
    my $nosys = MockInvDbh->new(inv_present => 1, sys_col => 0);
    fetchconfig::History::_probe_inv_tables($nosys);
    fetchconfig::History::_apply_op($nosys, {
        op => 'inv_current', dev_id => 'sw2', status => 'successful', source => 'snmp',
        run_end => 200, vendor => 'PLANET Technology Corporation', model => 'IGS-5225-8P4S',
        serial => 'S9', os_version => 'v5', member_count => 1,
        sysname => 'U-5141-SW1', syslocation => 'Meistercontainer_511', syscontact => 'IT',
        hw_set => '', history_on => 1,
    });
    my ($iv2) = grep { $_->{sql} =~ /INSERT INTO device_inventory\b/ } @{ $nosys->{calls} };
    unlike($iv2->{sql}, qr/\bsysname\b/, 'inv_current omits the sys* columns when absent (pre-2.17)');

    # Pre-check gate: inventory tables absent -> every inv op is a no-op.
    my $absent = MockInvDbh->new(inv_present => 0);
    fetchconfig::History::_probe_inv_tables($absent);
    is(fetchconfig::History::_apply_op($absent, { op => 'inv_current', dev_id => 'x',
        status => 'successful', run_end => 1 }), 1, 'inv_current is a no-op when tables absent');
    is(fetchconfig::History::_apply_op($absent, { op => 'inv_reset', dev_id => 'x' }), 1,
       'inv_reset is a no-op when tables absent');
    ok(!(grep { $_->{sql} =~ /(?:INSERT INTO|DELETE FROM|UPDATE)\s+device_inventory/ } @{ $absent->{calls} }),
       'no inventory DML issued when the schema is absent (only the pg_class probe)');

    # op=rename extends to the inventory tables when present.
    $dbh = MockInvDbh->new(inv_present => 1);
    fetchconfig::History::_probe_inv_tables($dbh);
    fetchconfig::History::_apply_op($dbh, { op => 'rename', old_dev_id => 'a', new_dev_id => 'b' });
    my @ren = grep { $_->{sql} =~ /UPDATE\s+\S+\s+SET dev_id/ } @{ $dbh->{calls} };
    is(scalar(@ren), 6, 'rename updates 3 backup + 3 inventory tables');

    # rename with inventory tables absent -> only the 3 backup tables.
    $absent = MockInvDbh->new(inv_present => 0);
    fetchconfig::History::_probe_inv_tables($absent);
    fetchconfig::History::_apply_op($absent, { op => 'rename', old_dev_id => 'a', new_dev_id => 'b' });
    my @ren2 = grep { $_->{sql} =~ /UPDATE\s+\S+\s+SET dev_id/ } @{ $absent->{calls} };
    is(scalar(@ren2), 3, 'rename touches only backup tables when inventory absent');
}

# --- pw: credential aliases (needs Detector/Abstract) ------------------------
SKIP: {
    my $have = eval { require fetchconfig::model::Detector;
                      require fetchconfig::model::Abstract; 1 };
    skip "Detector/Abstract deps not loadable here", 26 unless $have;

    fetchconfig::model::Detector->parse_pw_line('t', 1, 'user $User1 username');
    fetchconfig::model::Detector->parse_pw_line('t', 2, 'pass $Pass1 secret');
    ok(fetchconfig::model::Detector->pw_present, 'pw_present true after defining aliases');
    my ($k, $v) = fetchconfig::model::Detector->pw_alias('$User1');
    is("$k/$v", 'user/username', 'pw_alias lookup returns kind + value');

    # A bad alias name is rejected (not stored).
    fetchconfig::model::Detector->parse_pw_line('t', 3, 'user 9bad value');
    ok(!fetchconfig::model::Detector->pw_alias('9bad'), 'invalid alias name rejected');

    # Read-time resolution through Abstract. Use a tiny subclass that defines
    # label(), since Abstract::log_error (hit on the error paths) calls it.
    { package MockLog2; sub new { bless {}, shift } sub error {} sub info {} sub debug {} }
    { package TMod; our @ISA = ('fetchconfig::model::Abstract'); sub label { 'tmod' } }
    my $self = bless { log => MockLog2->new }, 'TMod';
    is($self->_expand_pw_alias('user', '$User1'), 'username', 'user alias resolves in user slot');
    is($self->_expand_pw_alias('snmp_authpass', '$Pass1'), 'secret', 'pass alias resolves in an snmp secret slot');
    is($self->_expand_pw_alias('user', '$Pass1'), undef, 'wrong-kind alias -> undef');
    is($self->_expand_pw_alias('user', '$Nope'), undef, 'undefined alias -> undef');
    is($self->_expand_pw_alias('pass', 'literalpw'), 'literalpw', 'non-alias value passes through');

    # --- 9.80 grammar: quote / leading-escape / alias / literal ---------------
    # _deescape_first: first-character-only de-escape of an unquoted literal.
    {
        my $d = \&fetchconfig::model::Abstract::_deescape_first;
        is($d->('\\$abc'),       '$abc',         '_deescape_first: leading \\$ -> $');                 # \$abc
        is($d->('\\\\$xyz'),     '\\$xyz',       '_deescape_first: leading \\\\ -> \\, rest kept');    # \\$xyz
        is($d->('\\srv'),        '\\srv',        '_deescape_first: leading \\+other kept');            # \srv
        is($d->('DOMAIN\\user'), 'DOMAIN\\user', '_deescape_first: interior \\ untouched');
        is($d->('ab$cd'),        'ab$cd',        '_deescape_first: no leading \\ -> verbatim');
    }
    # Quoted => fully-literal (never an alias), even when it equals an alias name.
    is($self->_expand_pw_alias('pass', '"$abc"'),       '$abc',       'quoted "$abc" -> literal $abc');
    is($self->_expand_pw_alias('pass', '"$ab,cd"'),     '$ab,cd',     'quoted value with comma -> literal');
    is($self->_expand_pw_alias('user', '"$User1"'),     '$User1',     'quoted alias NAME -> literal, not resolved');
    is($self->_expand_pw_alias('pass', '"a\\"b"'),      'a"b',        'in-quote \\" -> literal quote');
    # Unquoted leading-escape literals.
    is($self->_expand_pw_alias('pass', '\\$abc'),       '$abc',       'unquoted \\$abc -> literal $abc');
    is($self->_expand_pw_alias('pass', '\\\\$xyz'),     '\\$xyz',     'unquoted \\\\$xyz -> literal \\$xyz');
    # $ + non-name char is not an alias -> literal; interior escapes untouched.
    is($self->_expand_pw_alias('pass', '$1pass'),       '$1pass',     '$+digit -> literal (not an alias)');
    is($self->_expand_pw_alias('pass', 'C:\\\\tools'),  'C:\\\\tools', 'interior \\\\ untouched');
    is($self->_expand_pw_alias('pass', 'pa\\$\\$'),     'pa\\$\\$',   'interior \\$ untouched');
    is($self->_expand_pw_alias('user', 'DOMAIN\\user'), 'DOMAIN\\user', 'DOMAIN\\user verbatim');

    # Malformed pw: lines are recorded for the pre-run validation gate (fetchconfig.pl
    # refuses to run, like a bad directory: line).
    {
        my @before = fetchconfig::model::Detector->pw_errors;
        fetchconfig::model::Detector->parse_pw_line('t', 9, 'bogus $X value');   # bad kind
        my @after = fetchconfig::model::Detector->pw_errors;
        ok(scalar(@after) > scalar(@before), 'malformed pw: line recorded in pw_errors for the gate');
    }

    # snmp_profile_file is a default:-only option (the parsed vendor file is
    # cached process-wide): a device-line value is ignored, the default: value
    # wins, and with neither set it falls back to the shipped snmp-profiles.conf.
    my $pdef = bless { log => MockLog2->new,
                       default_options => { snmp_profile_file => '/etc/fc/profiles.conf' } }, 'TMod';
    is(fetchconfig::SNMPInventory::_profile_path($pdef, { snmp_profile_file => '/tmp/per-device.conf' }),
       '/etc/fc/profiles.conf',
       'snmp_profile_file: default: value wins, device-line value ignored');
    my $pnone = bless { log => MockLog2->new, default_options => {} }, 'TMod';
    like(fetchconfig::SNMPInventory::_profile_path($pnone, {}),
         qr{/snmp-profiles\.conf$},
         'snmp_profile_file: falls back to the shipped file when unset');
}

# --- pw_rows / pw_reference_errors: the --list-credentials lint ---------------
# (The full cross-table reference check iterates the parsed device table, which
# needs the driver's logger + model registration, so it is exercised end-to-end
# via `fetchconfig.pl --list-credentials` rather than in-process here. These
# cover the in-process-safe pieces: the alias listing and the clean/no-device
# path of the linter.)
SKIP: {
    my $have = eval { require fetchconfig::model::Detector;
                      require fetchconfig::model::Abstract; 1 };
    skip "Detector/Abstract deps not loadable here", 3 unless $have;

    # pw_rows: [kind, alias] only - values are secret and never listed.
    # $User1 (user) and $Pass1 (pass) were defined in the pw: block above.
    my %kind = map { $_->[1] => $_->[0] } fetchconfig::model::Detector->pw_rows;
    is($kind{'$User1'}, 'user', 'pw_rows: $User1 listed as a user alias (no value)');
    is($kind{'$Pass1'}, 'pass', 'pw_rows: $Pass1 listed as a pass alias (no value)');

    # No devices registered in this process => the reference linter is clean.
    is(scalar(fetchconfig::model::Detector->pw_reference_errors), 0,
       'pw_reference_errors: no devices -> no errors');
}

# --- .status file carries the inventory state + headline (9.80) --------------
{
    require fetchconfig::Mailer;

    my $slurp = sub { open(my $fh, '<', $_[0]) or die "open $_[0]: $!";
                      local $/; my $t = <$fh>; close $fh; $t };

    # successful: state + headline values
    my $d1 = tempdir(CLEANUP => 1);
    fetchconfig::Mailer->write_status_file({
        dev_id => 'dev1', repository => $d1, ts => 1700000000, elapsed => 7,
        success => 1, changed => 'unchanged', changes_only => 1,
        inv_status => 'successful', inv_source => 'snmp',
        inv_vendor => 'HPE Comware', inv_model => 'JH148A', inv_serial => 'CN6AH110LT',
        inv_os_version => '7.1.070', inv_member_count => 6, inv_hw_set => 'chassis:CN6AH110LT',
        inv_at => 1700000000,
    });
    my $t1 = $slurp->("$d1/dev1.status");
    like($t1, qr/^inventory=successful$/m,          '.status: inventory=successful');
    like($t1, qr/^inventory_vendor=HPE Comware$/m,  '.status: inventory_vendor');
    like($t1, qr/^inventory_model=JH148A$/m,        '.status: inventory_model');
    like($t1, qr/^inventory_serial=CN6AH110LT$/m,   '.status: inventory_serial');
    like($t1, qr/^inventory_member_count=6$/m,      '.status: inventory_member_count');
    like($t1, qr/^inventory_hw_set=chassis:CN6AH110LT$/m, '.status: inventory_hw_set');
    like($t1, qr/^inventory_at=1700000000$/m,       '.status: inventory_at (for snmp_inventory_interval)');

    # Round-trip: Detector::_status_inventory reads those back, mapped to inv_* keys.
    SKIP: {
        skip "Detector not loadable here", 3
            unless eval { require fetchconfig::model::Detector; 1 };
        my %inv = fetchconfig::model::Detector::_status_inventory("$d1/dev1.status");
        is($inv{inv_status}, 'successful', '_status_inventory: inv_status');
        is($inv{inv_at},     '1700000000', '_status_inventory: inv_at');
        is($inv{inv_hw_set}, 'chassis:CN6AH110LT', '_status_inventory: inv_hw_set');
    }

    # disabled: only the state line, no headline values
    my $d2 = tempdir(CLEANUP => 1);
    fetchconfig::Mailer->write_status_file({
        dev_id => 'dev2', repository => $d2, ts => 1700000000, elapsed => 0,
        success => 1, changed => 'unchanged', inv_status => 'disabled',
    });
    my $t2 = $slurp->("$d2/dev2.status");
    like($t2,   qr/^inventory=disabled$/m, '.status: inventory=disabled');
    unlike($t2, qr/^inventory_/m,          '.status: disabled carries no inventory_* values');

    # not configured for inventory: no inventory keys at all
    my $d3 = tempdir(CLEANUP => 1);
    fetchconfig::Mailer->write_status_file({
        dev_id => 'dev3', repository => $d3, ts => 1700000000, elapsed => 1,
        success => 1, changed => 'unchanged',
    });
    my $t3 = $slurp->("$d3/dev3.status");
    unlike($t3, qr/^inventory/m, '.status: no inventory keys when not configured');
}

done_testing();

# --- mock dbh for the inventory drain ops ------------------------------------
{
    package MockInvSth;
    sub new { my ($c, $p, $sql) = @_; bless { p => $p, sql => $sql }, $c }
    sub execute {
        my ($s, @bind) = @_;
        push @{ $s->{p}{calls} }, { sql => $s->{sql}, bind => [@bind] };
        return undef if $s->{p}{fail};
        return "0E0" if $s->{sql} =~ /^\s*SELECT/i;
        return "0E0" if $s->{sql} =~ /UPDATE\s+device_inventory\s+SET/;  # 0 rows -> INSERT path
        return 1;
    }
    sub fetchrow_arrayref {
        my $s = shift;
        return [1] if $s->{sql} =~ /information_schema/;
        if ($s->{sql} =~ /pg_attribute/) {   # column-presence probes
            if ($s->{sql} =~ /'fw_version'/) {       # device_inventory_component.fw_version (2.16)
                my $fw = exists $s->{p}{fw_col} ? $s->{p}{fw_col} : $s->{p}{inv_present};
                return $fw ? [1] : undef;
            }
            if ($s->{sql} =~ /'sysname'/) {          # device_inventory.sysname (2.17)
                my $sys = exists $s->{p}{sys_col} ? $s->{p}{sys_col} : $s->{p}{inv_present};
                return $sys ? [1] : undef;
            }
            return undef;
        }
        return ($s->{p}{inv_present} ? [1] : undef) if $s->{sql} =~ /pg_class/;
        return undef if $s->{sql} =~ /SELECT hw_set, os_version FROM device_inventory/;  # no prior
        undef;
    }
    sub finish { 1 }

    package MockInvDbh;
    sub new { my ($c, %o) = @_; bless { calls => [], %o }, $c }
    sub prepare { my ($s, $sql) = @_; MockInvSth->new($s, $sql) }
    sub commit { 1 } sub rollback { 1 } sub disconnect { 1 }
}

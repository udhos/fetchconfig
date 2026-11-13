# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2006 Everton da Silva Marques
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
# $Id: Detector.pm,v 9.28 2026/08/25 12:00:00 tammer Exp $

package fetchconfig::model::Detector; # fetchconfig/model/Detector.pm

use strict;
use warnings;
use Text::ParseWords ();
use fetchconfig::Mailer;
use fetchconfig::SNMPInventory;
use fetchconfig::model::GenericTemplate;
use fetchconfig::model::CiscoIOS;
use fetchconfig::model::CiscoIOSSSH;
use fetchconfig::model::CiscoCAT;
use fetchconfig::model::CiscoASA;
use fetchconfig::model::CiscoASASSH;
use fetchconfig::model::FortiGate;
use fetchconfig::model::ProCurve;
use fetchconfig::model::ProCurveSSH;
use fetchconfig::model::ComwareSSH;
use fetchconfig::model::Parks;
use fetchconfig::model::Riverstone;
use fetchconfig::model::Dell;
use fetchconfig::model::Terayon;
use fetchconfig::model::DmSwitch;
use fetchconfig::model::3ComMSR;
use fetchconfig::model::MikroTik;
use fetchconfig::model::CiscoPIX;
use fetchconfig::model::TellabsMSR;
use fetchconfig::model::JunOS;
use fetchconfig::model::Acme;
use fetchconfig::model::Mediant;
use fetchconfig::model::CiscoSG300;
use fetchconfig::model::Coriant8600;
use fetchconfig::model::CiscoIOSXR;
use fetchconfig::model::NECUnivergeIX;
use fetchconfig::model::Hirschmann;
use fetchconfig::model::Zyxel;
use fetchconfig::model::TPLinkWebSG105E;
use fetchconfig::model::ProCurveWeb1700;
use fetchconfig::model::PLANET;
use fetchconfig::model::ArubaCXSSH;
use fetchconfig::model::NexusSSH;
use fetchconfig::model::MediantSBC;
use fetchconfig::model::ProCurveSNMP;

my $logger;
my $default_lock_dir;       # <dir of fetchconfig.pl>/.lock, set by init()
my $lock_dir_failed = 0;    # set if a device's lock dir could not be used (-> driver exits 10)
my $snmp_fatal_failed = 0;  # set if an snmp_fatal=on device's inventory failed (-> driver exits 11)
my %model_table;
my %dev_id_table;
my @dev_order;          # dev_ids in device-table order (for the sequential fetch phase)
my %dev_info_table;

# The optional directory: allowlist. When at least one "directory:" line is
# present in the device table, repository= and template_dir= values are
# restricted to the listed directories (by tag or by exact path). Populated
# by parse(); empty means no allowlist configured (no enforcement).
#   %dir_allow_tag  : $TAG    -> { type => repository|template, path => ... }
#   %dir_allow_path : "type\0path" -> 1   (path with one trailing slash stripped)
my %dir_allow_tag;
my %dir_allow_path;
my $dir_allow_present = 0;
my %warned_unlisted_dir;   # F2: "no allowlist entry" warned once per dir per run
my $dir_allow_fetch_run_none = 0;   # set by "directory: fetch_run none"
my $dir_allow_report_none = 0;      # set by "directory: report none" (reporting disabled)
my @dir_allow_rows;      # ordered [type, tag, path] for --list-allowed-dirs
my @dir_allow_errors;    # [reason] for each rejected directory: line (for the linter)

# pw: credential aliases (engine 9.80), modelled on directory: tags.
#   %pw_tag : $Alias -> { kind => 'user'|'pass', value => ... }
# Referenced as the whole value of a credential option (user=/pass=/enable=/
# snmp_*); resolved read-time in Abstract::dev_option. See the 9.80 CR.
my %pw_tag;
my @pw_errors;           # [reason] for each rejected pw: line (for the linter)

#
# Only non-whitespace characters that are also safe to use unquoted
# in a filesystem path (dev_id ends up as part of a directory/file
# name under the repository, see Abstract.pm::dump_config) and as a
# literal (quotemeta'd) regex fragment (Abstract.pm::scan_dir). No
# '/', '..', or shell/regex metacharacters.
#
my $DEV_ID_RE = qr/^[\w.-]+$/;

#
# Returns $line with any pass=... / enable=... / community=... value
# replaced by '***', so raw device_table lines can be logged (e.g. on a
# parse error) without leaking cleartext credentials.
#
sub mask_secrets {
    my ($line) = @_;

    (my $masked = $line) =~ s/\b(pass|enable|community|snmp_community|snmp_write_community|snmp_authpass|snmp_privpass)=[^,\s]*/$1=***/gi;

    $masked;
}

# Read the inventory_* lines back out of an existing <dev_id>.status file, mapped
# to the inv_* arg names record_result/write_status_file use (inventory=X ->
# inv_status=X, inventory_at=N -> inv_at=N, ...). Used by snmp_inventory_interval
# to decide whether to skip this run's SNMP read and carry the last result
# forward. Returns () when the file or an inventory record is absent.
my %INV_STATUS_KEY = (
    inventory              => 'inv_status',
    inventory_source       => 'inv_source',
    inventory_vendor       => 'inv_vendor',
    inventory_model        => 'inv_model',
    inventory_serial       => 'inv_serial',
    inventory_os_version   => 'inv_os_version',
    inventory_sysname      => 'inv_sysname',
    inventory_syslocation  => 'inv_syslocation',
    inventory_syscontact   => 'inv_syscontact',
    inventory_member_count => 'inv_member_count',
    inventory_hw_set       => 'inv_hw_set',
    inventory_at           => 'inv_at',
);
sub _status_inventory {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my %s;
    while (my $ln = <$fh>) {
	$ln =~ s/[\r\n]+$//;
	$s{$1} = $2 if $ln =~ /^([A-Za-z_]+)=(.*)$/;
    }
    close $fh;
    return () unless defined $s{inventory};
    my %r;
    for my $k (keys %INV_STATUS_KEY) {
	$r{ $INV_STATUS_KEY{$k} } = $s{$k} if exists $s{$k};
    }
    return %r;
}

sub parse {
    my ($class, $file, $num, $line, $lookup_only) = @_;

    if (ref $class) { die "class method called as object method"; }
    unless (@_ == 4 || @_ == 5) { die "usage: $class->parse(\$file, \$line_num, \$line, [\$lookup_only])"; }

    #$logger->debug("Detector->parse: " . mask_secrets($line));

    #
    ## global e-mail summary configuration (independent of any model)
    # email: from=config.backup@acme.com,to=admin@acme.com,smtp=FQDN,user=xxx,password=xxx
    #
    if ($line =~ /^\s*email:\s*(.*)$/) {
	fetchconfig::Mailer->parse_email_line($file, $num, $line, $1);
	return;
    }

    #
    ## optional PostgreSQL backup-history writer (default:-level, fleet-wide).
    ## Inert unless set; DBI/DBD::Pg load only then. See fetchconfig::History.
    # db: db_inst=fetchconfig,db_user=fetchconfig_dashboard,db_pass=xxx,db_host=localhost
    #
    if ($line =~ /^\s*db:\s*(.*)$/) {
	require fetchconfig::History;
	fetchconfig::History->parse_db_line($file, $num, $line, $1, $logger);
	return;
    }

    #
    ## directory allowlist (optional). When present, repository= and
    ## template_dir= values are restricted to these directories.
    # directory: repository $REPO1     /usr/local/fetchconfig/config
    # directory: template   $TEMPLATE1 /usr/local/fetchconfig/templates
    #
    if ($line =~ /^\s*directory:\s*(.*)$/) {
	$class->parse_directory_line($file, $num, $1);
	return;
    }

    #
    ## credential aliases (optional). Define a username/password once and
    ## reference it as $Alias on any default:/device line, like directory: tags.
    # pw: user $User1 username
    # pw: pass $Pass1 secret
    #
    if ($line =~ /^\s*pw:\s*(.*)$/) {
	$class->parse_pw_line($file, $num, $1);
	return;
    }

    if ($line =~ /^\s*default:/) {
	#
        ## global        model           options
        # default:       cisco-ios       user=backup,pass=san,enable=san
	#
	if ($line !~ /^\s*(\S+)\s+(\S+)\s+(\S.*)$/) {
	    $logger->error("unrecognized default at file=$file line=$num: " . mask_secrets($line));
	    return;
	}

	my @row = ($1, $2, $3);
	my $model_label = shift @row;

	$model_label = $row[0];
	my $mod = $model_table{$model_label};
	if (ref $mod) {
	    shift @row;
	    $mod->default_options($file, $num, $line, @row);
	    return;
	}

	$logger->error("unknown model '$model_label' at file=$file line=$num: " . mask_secrets($line));

	return;
    }

    #
    ## model         dev-unique-id   hostname        device-specific-options
    #cisco-ios       spo2            10.0.0.1 user=backup,pass=san,enable=fran
    #

    if ($line !~ /^\s*(\S+)\s+(\S+)\s+(\S+)\s*(.*)$/) {
	$logger->error("unrecognized device at file=$file line=$num: " . mask_secrets($line));
	return;
    }

    my @row = ($1, $2, $3, $4);
    my $model_label = shift @row;

    my $mod = $model_table{$model_label};
    if (! ref $mod) {
	$logger->error("unknown model '$model_label' at file=$file line=$num: " . mask_secrets($line));
	return;
    }

    my $dev_id = shift @row;

    if ($dev_id !~ $DEV_ID_RE) {
	$logger->error("invalid dev_id '$dev_id' at file=$file line=$num (must match $DEV_ID_RE): " . mask_secrets($line));
	return;
    }

    # The dev_id becomes a directory under the repository. "." is a
    # legitimate character inside a hostname (sw01.example.com), but a
    # dev_id made ONLY of dots would resolve to the repository itself
    # (".") or its PARENT ("..") and write backups outside the
    # per-device folder. Reject those.
    if ($dev_id =~ /^\.+$/) {
	$logger->error("invalid dev_id '$dev_id' at file=$file line=$num (must not consist only of dots): " . mask_secrets($line));
	return;
    }

    my $dev_id_linenum = $dev_id_table{$dev_id};
    if (defined($dev_id_linenum)) {
	$logger->error("duplicated dev_id=$dev_id at file=$file line=$num: " . mask_secrets($line) . " (previous at line $dev_id_linenum)");
	return;
    }

    $dev_id_table{$dev_id} = $num;

    my $dev_host = shift @row;

    my $dev_opt_tab = {};

    $mod->parse_options("dev=$dev_id",
			$file, $num, $line,
			$dev_opt_tab,
			@row);

    # keep= becomes "how many backups to retain" and is used arithmetically
    # in purge_ancient (@files - keep). A non-numeric value coerces to 0 and
    # a negative one over-counts, either of which would DELETE EVERY backup.
    # Reject it at load time - the device-specific value, or the inherited
    # default: value - so a typo fails the run instead of destroying history
    # on the next pass. ("keep" unset is caught later as its own error.)
    {
	my $keep = $dev_opt_tab->{keep};
	$keep = $mod->{default_options}->{keep} unless defined $keep;
	if (defined($keep) && $keep !~ /^[1-9]\d*$/) {
	    $logger->error("invalid keep=$keep for dev_id=$dev_id at file=$file line=$num"
		. " (must be a positive integer): " . mask_secrets($line));
	    return;
	}
    }

    # Register the device. Since 9.58 parse() never fetches: every
    # device line is recorded here (model, host, merged options, and
    # the source file/line for messages), and the fetching happens in a
    # second phase through fetch_device() - sequentially, or in parallel
    # worker processes (see fetchconfig.pl -P). The lookup modes (-g,
    # -l, ...) use exactly the same registration and simply never call
    # fetch_device().
    $dev_info_table{$dev_id} = {
	model       => $mod,
	dev_host    => $dev_host,
	dev_opt_tab => $dev_opt_tab,
	file        => $file,
	num         => $num,
	line        => $line,
    };
    push @dev_order, $dev_id;

    return;
}

#
# Phase 2: fetch one registered device. This is the per-device work
# that used to run inline in parse(); it is unchanged apart from
# reading its inputs from the registration record. Returns nothing;
# the outcome is reported through Mailer::record_result (which also
# writes the .status file) exactly as before.
#
sub fetch_device {
    my ($class, $dev_id) = @_;

    my $info = $dev_info_table{$dev_id};
    if (!defined($info)) {
	$logger->error("fetch_device: unknown device: $dev_id");
	return;
    }

    my ($mod, $dev_host, $dev_opt_tab, $file, $num, $line) =
	@{$info}{qw(model dev_host dev_opt_tab file num line)};

    # "to" (available for all models) overrides, for this device
    # only, who receives the backup summary e-mail; see Mailer.pm.
    my $dev_email_to = $dev_opt_tab->{to};

    my ($latest_dir, $latest_file);

    #
    # "changes_only" is true: configuration is saved only when changed
    # "changes_only" is false: configuration is always saved
    #
    my $dev_changes_only = $mod->dev_option($dev_opt_tab, "changes_only");

    my $dev_run = $mod->dev_option($dev_opt_tab, "on_fetch_run");
    my $dev_cat = $mod->dev_option($dev_opt_tab, "on_fetch_cat");

    # Announce the device first, so anything logged while locating the
    # previous backup (e.g. "there is no latest config" on a freshly added
    # device) appears inside this device's block, not before it.
    $logger->info("-----[$dev_id]--------------------------------------------------------------------------------");

    #
    # Do we need to locate the latest backup?
    # - changes_only means we need to compare in order to detect change
    # - on_fetch_run means we need to pass it to the external program
    # - on_fetch_cat means we need to copy it to stdout
    #
    if ($dev_changes_only || $dev_run || $dev_cat) {
	($latest_dir, $latest_file) = $mod->find_latest($dev_id, $dev_opt_tab);
    }

    my $fetch_ts_start = time;
    $logger->info("dev=$dev_id host=$dev_host: retrieving config at " . scalar(localtime($fetch_ts_start)));

    # System-directory check, ALWAYS applied (allowlist or not): a
    # repository=, template_dir= or on_fetch_run program under /bin, /etc,
    # /usr/lib, ... is rejected and the device skipped. See @SYSTEM_DIRS.
    {
	my $rejected;
	for my $opt ('repository', 'template_dir') {
	    my $val = $mod->dev_option_raw($dev_opt_tab, $opt);
	    next unless defined($val) && length($val) && $val !~ /^\$/;   # $TAG resolved later
	    if (my $why = _system_dir_path($val)) {
		$logger->error("dev=$dev_id host=$dev_host: $opt=$val is $why - not allowed");
		$rejected = 1;
	    }
	}
	my $run = $mod->dev_option_raw($dev_opt_tab, 'on_fetch_run');
	if (defined($run) && length($run) && $run !~ /^\$/) {
	    my ($prog) = Text::ParseWords::shellwords($run);
	    my $dir = (defined($prog) && $prog =~ m{/}) ? ($prog =~ s{/[^/]*$}{}r) : '';
	    if (length($dir) && (my $why = _system_dir_path($dir))) {
		$logger->error("dev=$dev_id host=$dev_host: on_fetch_run program is in $why - not allowed");
		$rejected = 1;
	    }
	}
	if ($rejected) {
	    my $fetch_elap = time - $fetch_ts_start;
	    $logger->info("dev=$dev_id host=$dev_host: config retrieval took $fetch_elap secs");
	    return;
	}
    }

    # Without a directory: allowlist nothing restricts where repository=,
    # template_dir= or on_fetch_run may point (beyond the system-directory
    # check above). Say so once per distinct directory per run, so an
    # operator can see exactly which paths are unrestricted and decide
    # whether to add a directory: section. Not an error: installations
    # older than the allowlist feature have no such section.
    if (!$class->dir_allowlist_present) {
	for my $opt ('repository', 'template_dir', 'on_fetch_run') {
	    my $val = $mod->dev_option_raw($dev_opt_tab, $opt);
	    next unless defined($val) && length($val);
	    my $dir = $val;
	    if ($opt eq 'on_fetch_run') {
		my ($prog) = Text::ParseWords::shellwords($val);
		$dir = (defined($prog) && $prog =~ m{/}) ? ($prog =~ s{/[^/]*$}{}r) : '';
		next unless length $dir;
	    }
	    next if $warned_unlisted_dir{"$opt\x00$dir"}++;
	    $logger->info("warning: $opt directory $dir has no directory: allowlist entry (unrestricted; add a directory: section to the device table to restrict it)");
	}
    }

    # directory: allowlist enforcement (only if a directory: section exists).
    # repository= and template_dir= must resolve to an allowed directory of
    # the matching type; a $TAG is expanded to its path in the option table.
    # An off-list, wrong-type, undefined-tag or illegal-content value is
    # rejected here at fetch time and this device is skipped (a value from a
    # default: line rejects every device that inherits it).
    if ($class->dir_allowlist_present) {
	my $rejected;

	# The allowlist, if present, must define all required types.
	for my $miss ($class->dir_allow_missing_types) {
	    $logger->error("dev=$dev_id host=$dev_host: $miss");
	    $rejected = 1;
	}

	for my $spec ([ 'repository', 'repository' ], [ 'template', 'template_dir' ]) {
	    my ($type, $opt) = @$spec;
	    # the EFFECTIVE value (device line or inherited from default:), raw
	    my $val = $mod->dev_option_raw($dev_opt_tab, $opt);
	    next unless defined($val) && length($val);
	    my ($ok, $resolved) = $class->resolve_allowed_dir($type, $val);
	    if (!$ok) {
		$logger->error("dev=$dev_id host=$dev_host: $opt not allowed: $resolved");
		$rejected = 1;
	    }
	    elsif ($resolved ne $val) {
		# pin the expanded real path on the device so the fetch uses it
		$dev_opt_tab->{$opt} = $resolved;
	    }
	}

	# on_fetch_run is a command; its program directory must be allowed.
	{
	    my $val = $mod->dev_option_raw($dev_opt_tab, 'on_fetch_run');
	    if (defined($val) && length($val)) {
		my ($ok, $resolved) = $class->resolve_allowed_fetch_run($val);
		if (!$ok) {
		    $logger->error("dev=$dev_id host=$dev_host: on_fetch_run not allowed: $resolved");
		    $rejected = 1;
		}
		elsif ($resolved ne $val) {
		    $dev_opt_tab->{on_fetch_run} = $resolved;   # expand $TAG
		}
	    }
	}

	if ($rejected) {
	    my $fetch_elap = time - $fetch_ts_start;
	    $logger->info("dev=$dev_id host=$dev_host: config retrieval took $fetch_elap secs");
	    return;
	}
    }

    # Device locking (lock=yes). Acquire an exclusive flock on a per-device
    # lock file before fetching; $dev_lock holds the locked filehandle for
    # the rest of this sub and releases it when the sub returns. On
    # contention after the configured retries the device is recorded as
    # "skipped" (the existing backup state) and the process exit code is
    # left unchanged - a lock-skip is a per-device outcome, not a run
    # failure. If the lock directory cannot be created/used, that is fatal:
    # flag it so the driver exits 10 after the run.
    my $dev_lock;
    if ($mod->dev_option_flag($dev_opt_tab, 'lock', 0)) {
	# Record a "skipped" result with the SAME field set the normal
	# success/failure paths use - in particular repository=, so the
	# per-device status file can be written, and to=/elapsed= so the
	# mail routing and timing are right. (Omitting repository was the
	# "cannot write status file: no repository" error.)
	my $record_skip = sub {
	    fetchconfig::Mailer->record_result(
		dev_id       => $dev_id,
		dev_host     => $dev_host,
		ts           => $fetch_ts_start,
		elapsed      => time - $fetch_ts_start,
		repository   => $mod->dev_option($dev_opt_tab, "repository"),
		changes_only => $dev_changes_only,
		state        => 'skipped',
		size         => undef,
		changed      => 'n/a',
		to           => $dev_email_to,
	    );
	};

	my $lock_dir = $mod->lock_dir_resolve($dev_opt_tab, $default_lock_dir);
	if (!defined($lock_dir)) {
	    $lock_dir_failed = 1;
	    $logger->error("dev=$dev_id host=$dev_host: lock requested but the lock directory is unusable - skipping");
	    $record_skip->();
	    return;
	}
	my $lock_path  = $mod->device_lock_path($lock_dir, $dev_id);
	my $lock_retry = $mod->dev_option_posint($dev_opt_tab, 'lock_retry', 5, 1);        # 0 allowed
	my $lock_wait  = $mod->dev_option_posint($dev_opt_tab, 'lock_retry_time', 10, 0);  # >=1
	my $got = $mod->acquire_device_lock($lock_path, $dev_id, $lock_retry, $lock_wait);
	if (!defined($got)) {
	    # could not even open the lock file - treat as lock-dir failure
	    $lock_dir_failed = 1;
	    $record_skip->();
	    return;
	}
	if ($got eq 'locked') {
	    $logger->info("dev=$dev_id host=$dev_host: skipped - locked by another run"
		. " (lock_retry=$lock_retry lock_retry_time=${lock_wait}s)");
	    $record_skip->();
	    return;
	}
	$dev_lock = $got;   # hold the lock for the duration of the fetch
    }

    # The model instance is reused across devices of the same model; clear any
    # prior device's save metadata so a failed fetch here cannot inherit it.
    delete $mod->{saved};

    my ($config_dir, $config_file) = $mod->fetch($file, $num, $line, $dev_id, $dev_host, $dev_opt_tab);

    my $fetch_elap = time - $fetch_ts_start;
    $logger->info("dev=$dev_id host=$dev_host: config retrieval took $fetch_elap secs");

    # --- SNMP device inventory (engine 9.80) ---------------------------------
    # Model-independent; runs regardless of the config fetch outcome (an SNMP-only
    # or backup-failed device still gets inventory). Writes to the dashboard DB via
    # the outbox (fetchconfig::History); never affects the config backup. A failed
    # attempt is a device error only when snmp_fatal=on (exit 11).
    my %inv_status_fields;   # merged into record_result so the .status file carries the result
    {
	# snmp_inventory_interval (seconds; 0 = every run, the default): on a device
	# whose ENTITY-MIB is slow to serve (large Comware IRF stacks), skip the SNMP
	# read when the last successful inventory is younger than the interval and
	# carry that result forward into this run's .status -- so config backups stay
	# fast while inventory refreshes on its own cadence. The DB row is left as the
	# last successful collection; a failed/absent prior forces a fresh read.
	my $inv_interval = $mod->dev_option_posint($dev_opt_tab, 'snmp_inventory_interval', 0, 0) || 0;
	my %prior;
	if ($inv_interval > 0) {
	    my $repo = $mod->dev_option($dev_opt_tab, "repository");
	    %prior = _status_inventory("$repo/$dev_id.status")
		if defined($repo) && length($repo);
	}
	my $within = ($inv_interval > 0
	    && defined($prior{inv_status}) && $prior{inv_status} eq 'successful'
	    && defined($prior{inv_at}) && $prior{inv_at} =~ /^\d+$/
	    && ($fetch_ts_start - $prior{inv_at}) >= 0
	    && ($fetch_ts_start - $prior{inv_at}) < $inv_interval
	    && fetchconfig::SNMPInventory->mode($mod, $dev_opt_tab) eq 'on');

	if ($within) {
	    # Within the interval: reuse the last inventory, skip the slow SNMP read.
	    %inv_status_fields = %prior;
	    # Mark this run's SNMP read as skipped-by-interval so the summary mail can
	    # show "not due" rather than the carried-forward "success". This flag reaches
	    # record_result (-> the @results row) but is NOT one of the fixed inventory_*
	    # keys write_status_file persists, so it never lands in .status.
	    $inv_status_fields{inv_notdue} = 1;
	    my $age = $fetch_ts_start - $prior{inv_at};
	    $logger->info("dev=$dev_id host=$dev_host: SNMP inventory skipped "
			  . "(snmp_inventory_interval=${inv_interval}s; last read ${age}s ago)");
	}
	else {
	my $inv_ts   = time;
	my $inv      = fetchconfig::SNMPInventory->collect($mod, $dev_id, $dev_host, $dev_opt_tab);
	my $inv_elap = time - $inv_ts;
	my $inv_status = defined($inv->{status}) ? $inv->{status} : 'none';

	# Carry the inventory result into the per-device .status file (via
	# record_result below), in addition to the DB. 'none' writes nothing.
	if ($inv_status ne 'none') {
	    %inv_status_fields = (
		inv_status       => $inv_status,
		inv_source       => $inv->{source},
		inv_vendor       => $inv->{vendor},
		inv_model        => $inv->{model},
		inv_serial       => $inv->{serial},
		inv_os_version   => $inv->{os_version},
		inv_sysname      => $inv->{sysname},
		inv_syslocation  => $inv->{syslocation},
		inv_syscontact   => $inv->{syscontact},
		inv_member_count => $inv->{member_count},
		inv_hw_set       => $inv->{hw_set},
	    );
	    $inv_status_fields{inv_at} = $fetch_ts_start
		if $inv_status eq 'successful' || $inv_status eq 'failed';
	}

	# One per-device summary line for the SNMP inventory outcome, like the
	# "config retrieval took N secs" line above, so every run shows what the
	# inventory did for each device, including its own elapsed time (the
	# config-retrieval figure does not include the SNMP work). 'none' (device
	# not configured for inventory at all) stays silent.
	if ($inv_status eq 'successful') {
	    my $nc = scalar(@{ $inv->{components} || [] });
	    my @d;
	    push @d, "vendor=$inv->{vendor}"        if defined($inv->{vendor})       && length($inv->{vendor});
	    push @d, "model=$inv->{model}"          if defined($inv->{model})        && length($inv->{model});
	    push @d, "serial=$inv->{serial}"        if defined($inv->{serial})       && length($inv->{serial});
	    push @d, "members=$inv->{member_count}" if defined($inv->{member_count}) && length($inv->{member_count});
	    push @d, "components=$nc";
	    $logger->info("dev=$dev_id host=$dev_host: SNMP inventory read successful ("
			  . join(' ', @d) . ") in $inv_elap secs");
	}
	elsif ($inv_status eq 'failed') {
	    my $e = (defined($inv->{error}) && length($inv->{error}))
		  ? $inv->{error} : 'no usable inventory';
	    $logger->info("dev=$dev_id host=$dev_host: SNMP inventory read failed after $inv_elap secs: $e");
	}
	elsif ($inv_status eq 'disabled') {
	    $logger->info("dev=$dev_id host=$dev_host: SNMP inventory disabled for this device "
			  . "(snmp_inventory=off, or credentials incomplete; last-good data kept)");
	}

	if ($inv_status ne 'none') {
	    my $inv_repo = $mod->dev_option($dev_opt_tab, "repository");
	    fetchconfig::Mailer->record_inventory(
		dev_id         => $dev_id,
		repository     => $inv_repo,
		ts             => $fetch_ts_start,
		elapsed        => (time - $fetch_ts_start),
		status         => $inv_status,
		source         => $inv->{source},
		vendor         => $inv->{vendor},
		vendor_raw     => $inv->{vendor_raw},
		model          => $inv->{model},
		serial         => $inv->{serial},
		os_version     => $inv->{os_version},
		sysname        => $inv->{sysname},
		syslocation    => $inv->{syslocation},
		syscontact     => $inv->{syscontact},
		member_count   => $inv->{member_count},
		member_serials => $inv->{member_serials},
		hw_set         => $inv->{hw_set},
		history_on     => fetchconfig::SNMPInventory->flag($mod, $dev_opt_tab, 'snmp_inventory_history', 1),
	    );
	    if ($inv_status eq 'successful') {
		for my $c (@{ $inv->{components} || [] }) {
		    fetchconfig::Mailer->record_inventory_component(
			dev_id        => $dev_id,
			repository    => $inv_repo,
			member_index  => $c->{member_index},
			comp_class    => $c->{comp_class},
			comp_position => $c->{comp_position},
			model         => $c->{model},
			serial        => $c->{serial},
			sw_version    => $c->{sw_version},
			fw_version    => $c->{fw_version},
			hw_rev        => $c->{hw_rev},
			is_primary    => $c->{is_primary},
		    );
		}
	    }
	    if ($inv_status eq 'failed'
		&& fetchconfig::SNMPInventory->flag($mod, $dev_opt_tab, 'snmp_fatal', 0)) {
		$snmp_fatal_failed = 1;
		$logger->error("dev=$dev_id host=$dev_host: SNMP inventory failed and snmp_fatal=on");
	    }
	}
	}   # end else (inventory not skipped by snmp_inventory_interval)
    }

    if (!defined($config_dir)) {
	fetchconfig::Mailer->record_result(
	    dev_id       => $dev_id,
	    dev_host     => $dev_host,
	    ts           => $fetch_ts_start,
	    elapsed      => time - $fetch_ts_start,   # config fetch + SNMP inventory
	    repository   => $mod->dev_option($dev_opt_tab, "repository"),
	    changes_only => $dev_changes_only,
	    success      => 0,
	    size         => undef,
	    changed      => 'n/a',
	    to           => $dev_email_to,
	    %inv_status_fields,
	    );
	return;
    }

    my $curr = "$config_dir/$config_file";

    my $backup_size = (stat($curr))[7];

    #
    # Belt-and-suspenders: Abstract::dump_config() now refuses to
    # write an empty backup in the first place, but treat a 0-byte
    # (or unreadable) file that somehow still made it to disk the
    # same way, rather than trust every current and future model to
    # always get this right. Discard the bogus file immediately -
    # left in place, it would never get cleaned up (it "differs"
    # from any real previous backup) and would poison every future
    # changed-vs-previous comparison for this device.
    #
    if (!defined($backup_size) || $backup_size == 0) {
	$logger->error("dev=$dev_id host=$dev_host: empty (0-byte) backup file: $curr - treating fetch as failed");

	$mod->config_discard($config_dir, $config_file);

	fetchconfig::Mailer->record_result(
	    dev_id       => $dev_id,
	    dev_host     => $dev_host,
	    ts           => $fetch_ts_start,
	    elapsed      => time - $fetch_ts_start,   # config fetch + SNMP inventory
	    repository   => $mod->dev_option($dev_opt_tab, "repository"),
	    changes_only => $dev_changes_only,
	    success      => 0,
	    size         => $backup_size,
	    changed      => 'n/a',
	    to           => $dev_email_to,
	    %inv_status_fields,
	    );
	return;
    }

    my $cfg_equal = 0; # false

    if (defined($latest_dir)) {
	$cfg_equal = $mod->config_equal($latest_dir, $latest_file, $config_dir, $config_file);
    }

    # For the optional DB history writer: a backup file is RETAINED unless it is
    # the changes_only "unchanged" case discarded below. Only a retained backup
    # gets a backup_versions row, so the save metadata (path/epoch/sha1, stashed
    # by dump_config) is passed to record_result only when kept.
    my $saved_meta = $mod->{saved};
    my $backup_kept = !($dev_changes_only && $cfg_equal);

    # DB history: the line delta for this retained backup's version row -
    # lines_added/lines_removed over the ignore-normalized diff against the
    # previous config. undef (baseline) when there is no previous to compare.
    my ($lines_added, $lines_removed);
    if ($backup_kept && $saved_meta && defined($latest_dir)) {
        my $prev_lines = $mod->config_norm_lines($latest_dir, $latest_file);
        my $curr_lines = $mod->config_norm_lines($config_dir, $config_file);
        if (defined($prev_lines) && defined($curr_lines)) {
            ($lines_added, $lines_removed) =
                fetchconfig::model::Abstract::line_delta($prev_lines, $curr_lines);
        }
    }

    #
    # Record this device's outcome for the end-of-run backup summary
    # e-mail (see Mailer.pm). "changed"/"unchanged" is only reported
    # when this run actually compared against the previous backup
    # (changes_only, on_fetch_run or on_fetch_cat above); otherwise
    # it's reported as "n/a" -- no extra repository scan is added
    # just for this report.
    #
    fetchconfig::Mailer->record_result(
	dev_id       => $dev_id,
	dev_host     => $dev_host,
	ts           => $fetch_ts_start,
	elapsed      => time - $fetch_ts_start,   # config fetch + SNMP inventory + compare
	repository   => $mod->dev_option($dev_opt_tab, "repository"),
	changes_only => $dev_changes_only,
	success      => 1,
	size         => $backup_size,
	# "initial" when this run saved the first-ever backup (no previous
	# config existed to compare against) - not a real change. Otherwise
	# changed/unchanged from the comparison, or n/a when not tracked.
	changed      => (!defined($latest_dir))
	            ? 'initial'
	            : (($dev_changes_only || $dev_run || $dev_cat)
	               ? ($cfg_equal ? 'unchanged' : 'changed')
	               : 'n/a'),
	# DB history: backup_versions fields, only for a retained backup.
	(($backup_kept && $saved_meta) ? (
	    path           => $saved_meta->{path},
	    file_timestamp => $saved_meta->{file_epoch},
	    sha1           => $saved_meta->{sha1},
	    lines_added    => $lines_added,
	    lines_removed  => $lines_removed,
	) : ()),
	to           => $dev_email_to,
	%inv_status_fields,
	);

    if ($dev_run) {
	$ENV{FETCHCONFIG_DEV_ID} = $dev_id;
	$ENV{FETCHCONFIG_DEV_HOST} = $dev_host;
	if (defined($latest_dir)) {
	    $ENV{FETCHCONFIG_PREV} = "$latest_dir/$latest_file" ;
	}
	else {
	    delete $ENV{FETCHCONFIG_PREV};
	}
	$ENV{FETCHCONFIG_CURR} = $curr;
	# Split the configured command into program + arguments ourselves and
	# run it with the list form of system(), which goes straight to
	# execvp() and never through /bin/sh. A single-string system() would
	# hand the whole line to the shell, so a device-table value like
	# "/path/prog ; rm -rf /" would execute the second command. Quoted
	# arguments ("a b") survive the split. on_fetch_run is therefore a
	# program plus literal arguments, not a shell command line.
	my @run_argv = Text::ParseWords::shellwords($dev_run);
	if (!@run_argv) {
	    $logger->error("dev=$dev_id host=$dev_host: on_fetch_run is empty after parsing");
	}
	else {
	    my $rc = system { $run_argv[0] } @run_argv;
	    if ($rc == -1) {
		$logger->error("dev=$dev_id host=$dev_host: on_fetch_run failed to start: $run_argv[0]: $!");
	    }
	    elsif ($rc & 127) {
		$logger->error("dev=$dev_id host=$dev_host: on_fetch_run killed by signal " . ($rc & 127));
	    }
	    elsif ($rc >> 8) {
		$logger->error("dev=$dev_id host=$dev_host: on_fetch_run exited with status " . ($rc >> 8));
	    }
	}
	delete $ENV{FETCHCONFIG_DEV_ID};
	delete $ENV{FETCHCONFIG_DEV_HOST};
	delete $ENV{FETCHCONFIG_PREV};
	delete $ENV{FETCHCONFIG_CURR};
    }

    if ($dev_cat) {
        local *IN;

        if (!open(IN, '<', $curr)) {
            $logger->error("could not read current config: $curr: $!");
            return;
        }

        my @cfg = <IN>;
        chomp @cfg;

        print STDOUT @cfg;

        close IN;
    }

    if ($dev_changes_only && $cfg_equal) {
	$logger->debug("dev=$dev_id host=$dev_host: discarding config unchanged since last run");
	$mod->config_discard($config_dir, $config_file);
    }

    $mod->purge_ancient($dev_id, $dev_opt_tab);

    # DB history: emit an expire event for each backup purge_ancient rotated out
    # (keyed by the same epoch the save-time version row used), so the writer can
    # mark the backup_versions row expired. No-op without a DB (History ignores
    # them when "db:" is unset).
    if (my $expired = $mod->{expired}) {
	my $repo = $mod->dev_option($dev_opt_tab, "repository");
	for my $epoch (@$expired) {
	    fetchconfig::Mailer->record_expire(
		dev_id         => $dev_id,
		repository     => $repo,
		file_timestamp => $epoch,
	    );
	}
    }
}

#
# Returns the resolved { model, dev_host, dev_opt_tab } hashref for
# $dev_id, as recorded by a previous lookup_only parse() call, or
# undef if $dev_id is unknown.
#
# --- directory: allowlist ------------------------------------------------

# Validate a directory path's CONTENT (not its existence): reject relative
# and traversal constructs and OS-inappropriate characters. We deliberately
# do NOT canonicalize (symlinked, version-free paths must be preserved), so
# a "/../" or "/./" must never be accepted. Returns () if OK, else a reason
# string.
# Directories that must never be used as a repository, template or
# fetch_run directory, whether or not a directory: allowlist is present:
# the OS itself lives there, and a backup written into one of them (or a
# template read from one) is almost certainly a misconfiguration or an
# attempt to plant a file somewhere privileged. A path is rejected if it
# IS one of these or is UNDER one of them. The root "/" is rejected too.
my @SYSTEM_DIRS = qw(
    /bin /sbin /lib /lib64 /libexec /usr/bin /usr/sbin /usr/lib /usr/lib64
    /usr/libexec /usr/share /usr/include /etc /boot /dev /proc /sys /run
    /var/run /var/lock
);
sub _system_dir_path {
    my ($path) = @_;
    return undef unless defined($path) && length($path);
    (my $p = $path) =~ s{/+$}{};            # drop trailing slashes
    $p =~ s{/{2,}}{/}g;                     # collapse "//"
    return 'the filesystem root "/"' if $p eq '';
    for my $sys (@SYSTEM_DIRS) {
        return "the system directory $sys" if $p eq $sys || index($p, "$sys/") == 0;
    }
    return undef;
}

sub _bad_dir_path {
    my ($path) = @_;
    return "empty path" unless defined($path) && length($path);
    return "contains NUL" if $path =~ /\x00/;
    return "contains a control character" if $path =~ /[\x01-\x1f\x7f]/;
    # traversal / relative components (any OS)
    return 'contains "/../"' if $path =~ m{(^|/)\.\.(/|$)};
    return 'contains "/./"'  if $path =~ m{(^|/)\.(/|$)};

    if ($^O eq 'MSWin32') {
        # drive (C:\...) or UNC (\\host\share...) root; accept / or \ as sep
        my $rest = $path;
        if    ($rest =~ /^[A-Za-z]:[\\\/]/) { $rest =~ s/^[A-Za-z]:// }
        elsif ($rest =~ /^\\\\[^\\\/]+[\\\/][^\\\/]+/) { }  # UNC
        else { return "not an absolute Windows path (drive or UNC root)"; }
        return 'contains a reserved character (< > : " | ? *)'
            if $rest =~ /[<>:"|?*]/;
        for my $comp (split m{[\\\/]+}, $rest) {
            next unless length $comp;
            return "reserved device name '$comp'"
                if $comp =~ /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i;
        }
        return ();
    }

    # Unix (AIX, Linux, ...)
    return "not an absolute path (must start with /)" unless $path =~ m{^/};
    return "contains an illegal character"
        unless $path =~ m{^[A-Za-z0-9_./ +\@:=~-]+$};
    return ();
}

# strip a single trailing slash for comparison (not for display)
sub _dir_key {
    my ($path) = @_;
    $path =~ s{/$}{} if length($path) > 1;
    return $path;
}

# parse one "directory:" line body: "<type> <$TAG> <path>"
sub parse_directory_line {
    my ($class, $file, $num, $body) = @_;
    $dir_allow_present = 1;

    # Special form: "directory: fetch_run none" - the fetch_run type is
    # satisfied, but no directory is permitted, so any on_fetch_run is
    # forbidden.
    if ($body =~ /^\s*fetch_run\s+none\s*$/) {
        $dir_allow_fetch_run_none = 1;
        push @dir_allow_rows, [ 'fetch_run', 'none', 'none' ];
        return;
    }

    # Special form: "directory: report none" - reporting is disabled; the
    # report type is satisfied and no report directory is permitted.
    if ($body =~ /^\s*report\s+none\s*$/) {
        $dir_allow_report_none = 1;
        push @dir_allow_rows, [ 'report', 'none', 'none' ];
        return;
    }

    if ($body !~ /^\s*(\S+)\s+(\S+)\s+(\S.*?)\s*$/) {
        my $m = "unrecognized directory at file=$file line=$num: directory: $body"; $logger->error($m); push @dir_allow_errors, $m; return;
    }
    my ($type, $tag, $path) = ($1, $2, $3);
    if ($type ne 'repository' && $type ne 'template' && $type ne 'fetch_run' && $type ne 'report' && $type ne 'lock') {
        my $m = "directory: type must be 'repository', 'template', 'fetch_run', 'report' or 'lock' (got '$type') at file=$file line=$num"; $logger->error($m); push @dir_allow_errors, $m; return;
    }
    if ($tag !~ /^\$[A-Za-z_][A-Za-z0-9_]*$/) {
        my $m = "directory: tag must look like \$NAME (got '$tag') at file=$file line=$num"; $logger->error($m); push @dir_allow_errors, $m; return;
    }
    if (exists $dir_allow_tag{$tag}) {
        my $m = "directory: duplicate tag '$tag' at file=$file line=$num"; $logger->error($m); push @dir_allow_errors, $m; return;
    }
    if (my $why = _bad_dir_path($path)) {
        my $m = "directory: illegal path '$path' ($why) at file=$file line=$num"; $logger->error($m); push @dir_allow_errors, $m; return;
    }
    # A system directory must never be allowlisted - otherwise the allowlist
    # could permit exactly what the device-value check below forbids (e.g.
    # declaring /usr/share as an allowed fetch_run directory).
    if (my $why = _system_dir_path($path)) {
        my $m = "directory: path '$path' is $why at file=$file line=$num"; $logger->error($m); push @dir_allow_errors, $m; return;
    }
    my $key = $type . "\x00" . _dir_key($path);
    $dir_allow_tag{$tag}   = { type => $type, path => $path };
    $dir_allow_path{$key}  = 1;
    push @dir_allow_rows, [ $type, $tag, $path ];
}

# Is on_fetch_run forbidden by "directory: fetch_run none"?
sub dir_allow_fetch_run_none { return $dir_allow_fetch_run_none; }

# Is reporting disabled by "directory: report none"?
sub dir_allow_report_none { return $dir_allow_report_none; }

# Which directory types the allowlist actually defines (for the all-types
# check). fetch_run is "defined" by a path entry OR by the none form.
sub dir_allow_types_present {
    my %t;
    for my $r (@dir_allow_rows) { $t{$r->[0]} = 1; }
    return %t;
}

# Is a directory allowlist configured?
sub dir_allowlist_present { return $dir_allow_present; }

# Ordered rows for --list-allowed-dirs: ([type, tag, path], ...)
sub dir_allowlist_rows { return @dir_allow_rows; }

# Parse-time errors for invalid directory: lines (for the linter).
sub dir_allowlist_errors { return @dir_allow_errors; }

# --- pw: credential aliases (engine 9.80) ---------------------------------

# Parse one "pw:" line body: "<kind> $Alias <value>", kind = user|pass. The value
# follows the same quoting rules as an inline user=/pass= value, so an alias is a
# drop-in for what you'd write inline. pass-kind values are masked in any log.
sub parse_pw_line {
    my ($class, $file, $num, $body) = @_;

    unless ($body =~ /^\s*(\S+)\s+(\S+)\s+(\S.*?)\s*$/) {
        my $m = "pw: unrecognized (expected 'pw: user|pass \$Alias value')";
        $logger->error("$m at file=$file line=$num") if $logger;
        push @pw_errors, $m;
        return;
    }
    my ($kind, $alias, $value) = ($1, $2, $3);

    # A pass-kind value must never reach the log in clear.
    my $safe = ($kind eq 'pass') ? "pw: $kind $alias ***" : "pw: $kind $alias $value";

    if ($kind ne 'user' && $kind ne 'pass') {
        my $m = "pw: kind must be 'user' or 'pass' (got '$kind')";
        $logger->error("$m at file=$file line=$num: $safe") if $logger;
        push @pw_errors, $m; return;
    }
    if ($alias !~ /^\$[A-Za-z_][A-Za-z0-9_]*$/) {
        my $m = "pw: alias must look like \$NAME (got '$alias')";
        $logger->error("$m at file=$file line=$num: $safe") if $logger;
        push @pw_errors, $m; return;
    }
    if (exists $pw_tag{$alias}) {
        my $m = "pw: duplicate alias '$alias'";
        $logger->error("$m at file=$file line=$num: $safe") if $logger;
        push @pw_errors, $m; return;
    }
    if (exists $dir_allow_tag{$alias}) {
        my $m = "pw: alias '$alias' clashes with a directory: tag";
        $logger->error("$m at file=$file line=$num: $safe") if $logger;
        push @pw_errors, $m; return;
    }

    $value = fetchconfig::model::Abstract::dequote_value($value);
    if (!length($value)) {
        my $m = "pw: empty value for alias '$alias'";
        $logger->error("$m at file=$file line=$num") if $logger;
        push @pw_errors, $m; return;
    }

    $pw_tag{$alias} = { kind => $kind, value => $value };
}

# Is any pw: alias configured? (used by --list-credentials)
sub pw_present { return %pw_tag ? 1 : 0; }

# Look up a pw: alias: returns ($kind, $value), or () if undefined.
sub pw_alias {
    my ($class, $alias) = @_;
    my $e = $pw_tag{$alias} or return ();
    return ($e->{kind}, $e->{value});
}

sub pw_errors { return @pw_errors; }

# Ordered rows for --list-credentials: ([kind, alias], ...). Values are NEVER
# included - pass-kind values are secret.
sub pw_rows {
    return map { [ $pw_tag{$_}{kind}, $_ ] } sort keys %pw_tag;
}

# Cross-table lint for --list-credentials: every credential-slot value that is an
# unquoted $Name reference must resolve to a defined alias of the right kind.
# Returns human-readable error strings (empty if clean). Quoted literals and
# escaped/ordinary values are skipped - only $Name references are checked.
sub pw_reference_errors {
    my ($class) = @_;
    my @errs;
    my @slots = fetchconfig::model::Abstract::pw_slots();
    for my $dev_id (@dev_order) {
        my $info = $dev_info_table{$dev_id} or next;
        my $mod  = $info->{model};
        my $tab  = $info->{dev_opt_tab} || {};
        for my $slot (@slots) {
            my $raw = exists $tab->{$slot} ? $tab->{$slot}
                    : ($mod && $mod->can('default_option') ? $mod->default_option($slot) : undef);
            next unless defined $raw;
            next if $raw =~ /^".*"$/s;                          # quoted literal
            next unless $raw =~ /^\$[A-Za-z_][A-Za-z0-9_]*$/;   # only $Name references
            my ($kind) = $class->pw_alias($raw);
            my $want = fetchconfig::model::Abstract::pw_slot_kind($slot);
            if (!defined $kind) {
                push @errs, "dev=$dev_id: $slot=$raw refers to an undefined pw: alias";
            } elsif (defined($want) && $kind ne $want) {
                push @errs, "dev=$dev_id: $slot=$raw is a '$kind' alias, not '$want'";
            }
        }
    }
    return @errs;
}

# Resolve/allow a repository= or template_dir= value against the allowlist.
# $type is 'repository' or 'template'. Returns ($ok, $resolved_path_or_reason):
#   - if the allowlist is not present: (1, $value) unchanged (no enforcement)
#   - if $value is a defined $TAG of the right type: (1, its path)
#   - if $value is a literal path allowed for that type: (1, $value)
#   - otherwise: (0, reason string)
# Also enforces path-content validation on a literal value even when it is
# on the list (defence in depth) - a listed path already passed, so this
# only bites a literal that somehow differs.
sub resolve_allowed_dir {
    my ($class, $type, $value) = @_;
    return (1, $value) unless $dir_allow_present;
    return (0, "empty value") unless defined($value) && length($value);

    if ($value =~ /^\$/) {
        my $e = $dir_allow_tag{$value};
        return (0, "undefined directory tag '$value'") unless $e;
        return (0, "tag '$value' is a $e->{type} directory, not $type")
            unless $e->{type} eq $type;
        return (1, $e->{path});
    }
    if (my $why = _bad_dir_path($value)) {
        return (0, "illegal path '$value' ($why)");
    }
    if (my $why = _system_dir_path($value)) {
        return (0, "'$value' is $why");
    }
    my $key = $type . "\x00" . _dir_key($value);
    return (1, $value) if $dir_allow_path{$key};
    return (0, "$type directory '$value' is not in the directory: allowlist");
}

# Resolve/allow an on_fetch_run value against the fetch_run allowlist. The
# value is a COMMAND (program plus optional arguments). The check is on the
# directory of the program (the first token): that directory must be an
# allowed fetch_run directory. A leading $TAG (a fetch_run tag) is expanded
# in place. Returns ($ok, $resolved_command_or_reason).
#   - allowlist absent: (1, $value) unchanged
#   - "directory: fetch_run none" in effect: (0, forbidden) if a value is set
#   - $TAG form ($CMD1/prog ...): tag must be a fetch_run tag; expands to
#     <path>/prog ...; allowed because the program sits in the tag's dir
#   - literal form: program must be absolute; its dirname must be an allowed
#     fetch_run directory
sub resolve_allowed_fetch_run {
    my ($class, $value) = @_;
    return (1, $value) unless $dir_allow_present;
    return (1, $value) unless defined($value) && length($value);

    if ($dir_allow_fetch_run_none) {
        return (0, "on_fetch_run is not permitted (directory: fetch_run none)");
    }

    # split into first token (program) and the remainder (arguments)
    my ($prog, $rest);
    if ($value =~ /^(\S+)(\s.*)?$/) { ($prog, $rest) = ($1, $2); }
    else { return (0, "empty on_fetch_run"); }
    $rest = '' unless defined $rest;

    if ($prog =~ /^(\$[A-Za-z_][A-Za-z0-9_]*)(.*)$/) {
        my ($tag, $tail) = ($1, $2);
        my $e = $dir_allow_tag{$tag};
        return (0, "undefined directory tag '$tag' in on_fetch_run") unless $e;
        return (0, "tag '$tag' is a $e->{type} directory, not fetch_run")
            unless $e->{type} eq 'fetch_run';
        # $tail is the part after the tag, e.g. "/mycmd.pl"; the program is
        # <tagpath><tail>. Its directory is the tag path (allowed) as long as
        # $tail names a file directly under it (no extra directory / traversal)
        my $rel = $tail;
        $rel =~ s{^/}{};
        if ($rel eq '' || $rel =~ m{/}) {
            return (0, "on_fetch_run '$tag$tail' must name a program directly in the tag directory");
        }
        if (my $why = _bad_dir_path("$e->{path}/$rel")) {
            return (0, "illegal on_fetch_run path ($why)");
        }
        return (1, "$e->{path}/$rel$rest");
    }

    # literal program path: must be absolute, its dirname must be allowed
    if ($prog !~ m{^/}) {
        return (0, "on_fetch_run program '$prog' must be an absolute path");
    }
    if (my $why = _bad_dir_path($prog)) {
        return (0, "illegal on_fetch_run path '$prog' ($why)");
    }
    (my $dir = $prog) =~ s{/[^/]+$}{};
    $dir = '/' if $dir eq '';
    my $key = 'fetch_run' . "\x00" . _dir_key($dir);
    return (1, $value) if $dir_allow_path{$key};
    return (0, "on_fetch_run directory '$dir' is not in the directory: allowlist");
}

# Verify that a present allowlist defines all required types. repository and
# template must each have at least one entry; fetch_run must have a path
# entry OR the "none" form. Returns a list of human-readable problems (empty
# if complete).
sub dir_allow_missing_types {
    return () unless $dir_allow_present;
    my %have = $_[0]->dir_allow_types_present;
    my @missing;
    push @missing, "repository" unless $have{repository};
    push @missing, "template"   unless $have{template};
    push @missing, "fetch_run"  unless ($have{fetch_run} || $dir_allow_fetch_run_none);
    push @missing, "report"     unless ($have{report}    || $dir_allow_report_none);
    return map { "directory: allowlist is missing a '$_' entry" } @missing;
}

sub device_info {
    my ($class, $dev_id) = @_;

    $dev_info_table{$dev_id};
}

#
# True if $id is a valid device id: it matches $DEV_ID_RE (the exact rule
# parse() enforces on the device table) and is not made only of dots. This is
# the single source of truth for the id syntax, reused by --rename-device-id so
# a renamed id can never be something the table parser would later reject.
#
sub valid_dev_id {
    my ($class, $id) = @_;
    return 0 unless defined($id) && $id =~ $DEV_ID_RE;
    return 0 if $id =~ /^\.+$/;
    return 1;
}

#
# True if any device's lock directory could not be created/used; the
# driver turns this into exit 10.
#
sub lock_dir_failed { return $lock_dir_failed; }
sub snmp_fatal_failed { return $snmp_fatal_failed; }

#
# Returns a sorted list of every dev_id resolved so far by
# lookup_only parse() calls (i.e. every device known from the
# currently loaded -devices=/-line= sources). Backs the -Z
# (check zero-byte backups for all devices) feature.
#
sub device_ids {
    my ($class) = @_;

    sort keys %dev_info_table;
}

#
# Every registered dev_id in device-table order (the order the fetch
# phase uses at -P 1, so the run's output order is unchanged from
# earlier versions).
#
sub device_ids_in_order {
    my ($class) = @_;

    @dev_order;
}

sub register {
    my ($class, $mod) = @_;

    $logger->debug("registering model: " . $mod->label);

    $model_table{$mod->label} = $mod;
}

# Return the registered model object for a label (e.g. "generic"), or undef.
sub model_by_label {
    my ($class, $label) = @_;
    return $model_table{$label};
}

sub init {
    my ($class, $log, $lock_dir) = @_;

    $logger = $log;
    $default_lock_dir = $lock_dir;
    $lock_dir_failed = 0;

    # Reset the directory: allowlist state, so a second load in one process
    # (a daemon, a test) does not inherit the previous table's allowlist.
    %dir_allow_tag   = ();
    %dir_allow_path  = ();
    $dir_allow_present = 0;
    $dir_allow_fetch_run_none = 0;
    $dir_allow_report_none = 0;
    @dir_allow_rows  = ();
    @dir_allow_errors = ();
    %warned_unlisted_dir = ();
    %pw_tag = ();
    @pw_errors = ();
    $snmp_fatal_failed = 0;

    fetchconfig::Mailer->init($log);

    $class->register(fetchconfig::model::GenericTemplate->new($log));
    $class->register(fetchconfig::model::CiscoIOS->new($log));
    $class->register(fetchconfig::model::CiscoIOSSSH->new($log));
    $class->register(fetchconfig::model::CiscoCAT->new($log));
    $class->register(fetchconfig::model::CiscoASA->new($log));
    $class->register(fetchconfig::model::CiscoASASSH->new($log));
    $class->register(fetchconfig::model::FortiGate->new($log));
    $class->register(fetchconfig::model::ProCurve->new($log));
    $class->register(fetchconfig::model::ProCurveSSH->new($log));
    $class->register(fetchconfig::model::ComwareSSH->new($log));
    $class->register(fetchconfig::model::Parks->new($log));
    $class->register(fetchconfig::model::Riverstone->new($log));
    $class->register(fetchconfig::model::Dell->new($log));
    $class->register(fetchconfig::model::Terayon->new($log));
    $class->register(fetchconfig::model::DmSwitch->new($log));
    $class->register(fetchconfig::model::3ComMSR->new($log));
    $class->register(fetchconfig::model::MikroTik->new($log));
    $class->register(fetchconfig::model::CiscoPIX->new($log));
    $class->register(fetchconfig::model::TellabsMSR->new($log));
    $class->register(fetchconfig::model::JunOS->new($log));
    $class->register(fetchconfig::model::Acme->new($log));
    $class->register(fetchconfig::model::Mediant->new($log));
    $class->register(fetchconfig::model::CiscoSG300->new($log));
    $class->register(fetchconfig::model::Coriant8600->new($log));
    $class->register(fetchconfig::model::CiscoIOSXR->new($log));
    $class->register(fetchconfig::model::NECUnivergeIX->new($log));
    $class->register(fetchconfig::model::Hirschmann->new($log));
    $class->register(fetchconfig::model::Zyxel->new($log));
    $class->register(fetchconfig::model::TPLinkWebSG105E->new($log));
    $class->register(fetchconfig::model::ProCurveWeb1700->new($log));
    $class->register(fetchconfig::model::PLANET->new($log));
    $class->register(fetchconfig::model::ArubaCXSSH->new($log));
    $class->register(fetchconfig::model::NexusSSH->new($log));
    $class->register(fetchconfig::model::MediantSBC->new($log));
    $class->register(fetchconfig::model::ProCurveSNMP->new($log));
}

1;

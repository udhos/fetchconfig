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
use fetchconfig::Mailer;
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
my %model_table;
my %dev_id_table;
my @dev_order;          # dev_ids in device-table order (for the sequential fetch phase)
my %dev_info_table;

#
# Only non-whitespace characters that are also safe to use unquoted
# in a filesystem path (dev_id ends up as part of a directory/file
# name under the repository, see Abstract.pm::dump_config) and as a
# literal (quotemeta'd) regex fragment (Abstract.pm::scan_dir). No
# '/', '..', or shell/regex metacharacters.
#
my $DEV_ID_RE = qr/^[\w.-]+$/;

#
# Returns $line with any pass=... / enable=... value replaced by
# '***', so raw device_table lines can be logged (e.g. on a parse
# error) without leaking cleartext credentials.
#
sub mask_secrets {
    my ($line) = @_;

    (my $masked = $line) =~ s/\b(pass|enable)=[^,\s]*/$1=***/gi;

    $masked;
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
    $logger->info("-----[$dev_id]--------------------------------------------------------------------------------");
    $logger->info("dev=$dev_id host=$dev_host: retrieving config at " . scalar(localtime($fetch_ts_start)));

    my ($config_dir, $config_file) = $mod->fetch($file, $num, $line, $dev_id, $dev_host, $dev_opt_tab);

    my $fetch_elap = time - $fetch_ts_start;
    $logger->info("dev=$dev_id host=$dev_host: config retrieval took $fetch_elap secs");

    if (!defined($config_dir)) {
	fetchconfig::Mailer->record_result(
	    dev_id       => $dev_id,
	    dev_host     => $dev_host,
	    ts           => $fetch_ts_start,
	    elapsed      => $fetch_elap,
	    repository   => $mod->dev_option($dev_opt_tab, "repository"),
	    changes_only => $dev_changes_only,
	    success      => 0,
	    size         => undef,
	    changed      => 'n/a',
	    to           => $dev_email_to,
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
	    elapsed      => $fetch_elap,
	    repository   => $mod->dev_option($dev_opt_tab, "repository"),
	    changes_only => $dev_changes_only,
	    success      => 0,
	    size         => $backup_size,
	    changed      => 'n/a',
	    to           => $dev_email_to,
	    );
	return;
    }

    my $cfg_equal = 0; # false

    if (defined($latest_dir)) {
	$cfg_equal = $mod->config_equal($latest_dir, $latest_file, $config_dir, $config_file);
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
	elapsed      => $fetch_elap,
	repository   => $mod->dev_option($dev_opt_tab, "repository"),
	changes_only => $dev_changes_only,
	success      => 1,
	size         => $backup_size,
	changed      => ($dev_changes_only || $dev_run || $dev_cat)
	            ? ($cfg_equal ? 'unchanged' : 'changed')
	            : 'n/a',
	to           => $dev_email_to,
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
	system($dev_run);
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
}

#
# Returns the resolved { model, dev_host, dev_opt_tab } hashref for
# $dev_id, as recorded by a previous lookup_only parse() call, or
# undef if $dev_id is unknown.
#
sub device_info {
    my ($class, $dev_id) = @_;

    $dev_info_table{$dev_id};
}

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

sub init {
    my ($class, $log) = @_;

    $logger = $log;

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

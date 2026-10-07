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

# The optional directory: allowlist. When at least one "directory:" line is
# present in the device table, repository= and template_dir= values are
# restricted to the listed directories (by tag or by exact path). Populated
# by parse(); empty means no allowlist configured (no enforcement).
#   %dir_allow_tag  : $TAG    -> { type => repository|template, path => ... }
#   %dir_allow_path : "type\0path" -> 1   (path with one trailing slash stripped)
my %dir_allow_tag;
my %dir_allow_path;
my $dir_allow_present = 0;
my $dir_allow_fetch_run_none = 0;   # set by "directory: fetch_run none"
my $dir_allow_report_none = 0;      # set by "directory: report none" (reporting disabled)
my @dir_allow_rows;      # ordered [type, tag, path] for --list-allowed-dirs
my @dir_allow_errors;    # [reason] for each rejected directory: line (for the linter)

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
	# "initial" when this run saved the first-ever backup (no previous
	# config existed to compare against) - not a real change. Otherwise
	# changed/unchanged from the comparison, or n/a when not tracked.
	changed      => (!defined($latest_dir))
	            ? 'initial'
	            : (($dev_changes_only || $dev_run || $dev_cat)
	               ? ($cfg_equal ? 'unchanged' : 'changed')
	               : 'n/a'),
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
# --- directory: allowlist ------------------------------------------------

# Validate a directory path's CONTENT (not its existence): reject relative
# and traversal constructs and OS-inappropriate characters. We deliberately
# do NOT canonicalize (symlinked, version-free paths must be preserved), so
# a "/../" or "/./" must never be accepted. Returns () if OK, else a reason
# string.
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
    if ($type ne 'repository' && $type ne 'template' && $type ne 'fetch_run' && $type ne 'report') {
        my $m = "directory: type must be 'repository', 'template', 'fetch_run' or 'report' (got '$type') at file=$file line=$num"; $logger->error($m); push @dir_allow_errors, $m; return;
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
    my ($class, $log) = @_;

    $logger = $log;

    # Reset the directory: allowlist state, so a second load in one process
    # (a daemon, a test) does not inherit the previous table's allowlist.
    %dir_allow_tag   = ();
    %dir_allow_path  = ();
    $dir_allow_present = 0;
    $dir_allow_fetch_run_none = 0;
    $dir_allow_report_none = 0;
    @dir_allow_rows  = ();
    @dir_allow_errors = ();

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

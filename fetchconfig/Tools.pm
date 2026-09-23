# fetchconfig - Retrieving configuration for multiple devices
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; see the GNU General Public License v2+.
#
# fetchconfig::Tools - the repository maintenance and lookup modes that
# back the command-line options -g, -l, -z, -Z, -o, -e, -s and -S. These
# never fetch a device; they read (and, with -D, prune) the repository of
# devices that Detector has already registered. Extracted from
# fetchconfig.pl in 9.61 (F5) with no change in behaviour: each sub keeps
# its name, arguments and exit codes; the two script globals they read,
# $log and $me, are passed in once via init().

package fetchconfig::Tools;

use strict;
use warnings;
use File::Path;
use File::Basename;
use fetchconfig::model::Detector;
use fetchconfig::model::Abstract;

my $log;   # the run's logger (fetchconfig::Logger), set by init()
my $me;    # the program's basename, for messages

sub init {
    my ($class, %arg) = @_;
    $log = $arg{log};
    $me  = $arg{me};
}

#
# Resolve $dev_id's model/repository (as recorded by a prior
# lookup_only parse() call) and scan its repository for backups.
# Returns (\@files, \%dir_tab), where @files lists backup filenames
# sorted newest-first and %dir_tab maps each filename to the
# directory it was found in -- or an empty list on error (after
# logging it).
#
sub scan_backups {
    my ($dev_id) = @_;

    my $info = fetchconfig::model::Detector->device_info($dev_id);

    if (!defined($info)) {
	$log->error("dev=$dev_id: unknown device (not found in -devices device list)");
	return ();
    }

    my $mod         = $info->{model};
    my $dev_opt_tab = $info->{dev_opt_tab};

    my $dev_repository = $mod->dev_option($dev_opt_tab, "repository");

    if (!defined($dev_repository)) {
	$log->error("dev=$dev_id: no repository configured for this device");
	return ();
    }

    my %dir_tab;

    if ($mod->scan_dir(\%dir_tab, $dev_id, $dev_repository)) {
	$log->error("dev=$dev_id: could not scan repository: $dev_repository");
	return ();
    }

    # Newest first by the PARSED timestamp (YYYYMMDD.HHMMSS), NOT by a
    # plain string sort of the whole name: the tz token that follows the
    # timestamp changes with DST (CET/CEST on AIX) and differs by
    # platform, and a filename_append_suffix may follow it, so a string
    # sort is only chronological by luck. See
    # Abstract::parse_backup_filename / sort_backups_desc.
    my @unparsed;
    my @files = fetchconfig::model::Abstract::sort_backups_desc($dev_id, [keys %dir_tab], \@unparsed);
    $log->error("dev=$dev_id: backup filename in unexpected format (ordered by name only): $_") for @unparsed;

    if (@files < 1) {
	$log->error("dev=$dev_id: no backed up config files found in $dev_repository");
	return ();
    }

    (\@files, \%dir_tab);
}

#
# Resolve backup number $index (1=latest, 2=next most recent, ...)
# of device $dev_id to a filesystem path. Returns ($path, $count)
# where $count is the total number of backups on file, or an empty
# list on error (after logging it).
#
sub locate_backup {
    my ($dev_id, $index) = @_;

    my ($files_ref, $dir_tab_ref) = scan_backups($dev_id);

    return () unless defined($files_ref);

    my @files   = @$files_ref;
    my %dir_tab = %$dir_tab_ref;

    my $count = @files;

    if ($index > $count) {
	$log->error("dev=$dev_id: requested backup $index but only $count backup(s) available");
	return ();
    }

    my $file = $files[$index - 1];
    my $dir  = $dir_tab{$file};

    ("$dir/$file", $count);
}

#
# Slurp a whole file in binary mode. Exits the program on error.
#
sub slurp_file {
    my ($dev_id, $path) = @_;

    local *CFG;

    if (!open(CFG, '<', $path)) {
	$log->error("dev=$dev_id: could not open backup file: $path: $!");
	exit 1;
    }

    binmode CFG;

    my $content;
    {
	local $/ = undef; # slurp whole file
	$content = <CFG>;
    }

    if (!close(CFG)) {
	$log->error("dev=$dev_id: could not close backup file: $path: $!");
	exit 1;
    }

    $content;
}

#
# Write $content to $out_file if defined, otherwise to stdout.
# Exits the program on error.
#
#
# $summary, if given, is appended to the result data as one trailing
# comment line "# <summary>" (the same text the run logs). It is used
# by the listing/check modes (-l, -z, -Z, -o, -s, -S) so their output
# is never empty and is self-describing: a reader (e.g. fetchconfig-web
# reading a -f file) can tell "checked, nothing found" from "nothing
# was written" without access to the exit status or stderr. It is
# added to the result stream regardless of destination, so stdout and
# -f carry identical content. NOT used for -g/-m: a retrieved config
# or a diff must stay byte-exact. Consumers of the listing formats
# must skip lines starting with "#".
#
sub emit_content {
    my ($dev_id, $content, $out_file, $what, $summary) = @_;

    $content .= "# $summary\n" if defined($summary) && length($summary);

    if (defined($out_file)) {
	local *OUT;

	if (!open(OUT, '>', $out_file)) {
	    $log->error("dev=$dev_id: could not write output file: $out_file: $!");
	    exit 1;
	}

	binmode OUT;

	if (!print(OUT $content)) {
	    $log->error("dev=$dev_id: could not write output file: $out_file: $!");
	    exit 1;
	}

	if (!close(OUT)) {
	    $log->error("dev=$dev_id: could not close output file: $out_file: $!");
	    exit 1;
	}

	$log->info("dev=$dev_id: wrote $what to $out_file");

	return;
    }

    binmode STDOUT;
    print STDOUT $content;
}

#
# Retrieve backup number $index (1=latest, 2=next most recent, ...)
# of device $dev_id from its configured repository, writing it to
# $out_file if given, or to stdout otherwise.
#
sub retrieve_config {
    my ($dev_id, $index, $out_file) = @_;

    my ($path, $count) = locate_backup($dev_id, $index);

    exit 1 unless defined($path);

    $log->debug("dev=$dev_id: retrieving backup [$index/$count]: $path");

    my $content = slurp_file($dev_id, $path);

    emit_content($dev_id, $content, $out_file, "backup [$index/$count] ($path)");
}

#
# Compare backup number $n_index (the newer one) against backup
# number $m_index (the older one, $m_index > $n_index) of device
# $dev_id, writing "diff"-style output to $out_file if given, or to
# stdout otherwise. Exits with the same status convention as the
# "diff" command: 0 if the two backups are identical, 1 if they
# differ, and 1 also if either backup could not be located or if
# "diff" itself failed to run.
#
sub compare_config {
    my ($dev_id, $n_index, $m_index, $out_file) = @_;

    my ($path_n, $count) = locate_backup($dev_id, $n_index);

    exit 1 unless defined($path_n);

    my ($path_m, $count2) = locate_backup($dev_id, $m_index);

    exit 1 unless defined($path_m);

    $log->debug("dev=$dev_id: comparing backup [$m_index] ($path_m) -> [$n_index] ($path_n)");

    local *DIFF;

    my $pid = open(DIFF, '-|');

    if (!defined($pid)) {
	$log->error("dev=$dev_id: could not fork to run diff: $!");
	exit 1;
    }

    if ($pid == 0) {
	# child: diff old(er) new(er), like the "diff" command itself
	exec('diff', $path_m, $path_n)
	    or do {
		# can't use $log here: we already forked away from
		# the parent's buffering/handles
		warn "$me: could not exec diff: $!\n";
		exit 127;
	    };
    }

    binmode DIFF;

    my $content;
    {
	local $/ = undef; # slurp whole output
	$content = <DIFF>;
    }

    close(DIFF);

    # diff(1) exit status: 0 = no differences, 1 = differences found,
    # 2 (or more) = trouble (e.g. a file could not be read)
    my $diff_exit = $? >> 8;

    if ($diff_exit > 1) {
	$log->error("dev=$dev_id: diff failed (exit=$diff_exit) comparing $path_m vs $path_n");
	exit 1;
    }

    emit_content($dev_id, $content, $out_file,
		 "diff between backup [$m_index] and [$n_index] ($path_m -> $path_n)");

    exit $diff_exit;
}

#
# List every backup on file for device $dev_id, newest first,
# numbered the same way "-n"/"-m" count them (1=latest, 2=next most
# recent, ...), writing the listing to $out_file if given, or to
# stdout otherwise.
#
sub list_backups {
    my ($dev_id, $out_file) = @_;

    my ($files_ref, $dir_tab_ref) = scan_backups($dev_id);

    exit 1 unless defined($files_ref);

    my @files   = @$files_ref;
    my %dir_tab = %$dir_tab_ref;

    my $count = @files;

    my $out = '';

    my $index = 0;

    foreach my $file (@files) {
	++$index;

	my $dir  = $dir_tab{$file};
	my $path = "$dir/$file";

	my $size = (stat($path))[7];
	$size = '?' unless defined($size);

	$out .= sprintf("%d\t%s\t%s\n", $index, $size, $path);
    }

    my $summary = "dev=$dev_id: listed $count backup(s)";
    $log->debug($summary);

    emit_content($dev_id, $out, $out_file, "listing of $count backup(s)", $summary);
}

#
# Check every backup on file for device $dev_id for a 0-byte
# length (e.g. left behind by a fetch that connected but failed to
# actually capture any configuration), numbered the same way
# "-n"/"-m"/"-l" count them (1=latest, 2=next most recent, ...).
# Only the zero-byte backups (if any) are printed, to $out_file if
# given, or to stdout otherwise; if none are found, nothing is
# printed (an all-clear message is still logged to stderr).
#
# Exits 1 if at least one zero-byte backup was found, 0 if all
# backups are non-empty -- suitable for scripting/monitoring, e.g.:
#   fetchconfig.pl -devices=device_table -z dev_id || alert "empty backup(s) for dev_id"
#
sub check_zero_backups {
    my ($dev_id, $out_file) = @_;

    my ($files_ref, $dir_tab_ref) = scan_backups($dev_id);

    exit 1 unless defined($files_ref);

    my @files   = @$files_ref;
    my %dir_tab = %$dir_tab_ref;

    my $count = @files;

    my $out = '';

    my $index = 0;
    my $zero_count = 0;

    foreach my $file (@files) {
	++$index;

	my $dir  = $dir_tab{$file};
	my $path = "$dir/$file";

	my $size = (stat($path))[7];

	if (!defined($size)) {
	    $log->error("dev=$dev_id: could not stat backup file: $path: $!");
	    next;
	}

	next if ($size != 0);

	++$zero_count;

	$out .= sprintf("%d\t%s\t%s\n", $index, $size, $path);
    }

    my $summary = ($zero_count > 0)
	? "dev=$dev_id: checked $count backup(s), found $zero_count zero-byte backup(s)"
	: "dev=$dev_id: checked $count backup(s), no zero-byte backups found";
    if ($zero_count > 0) { $log->debug($summary); } else { $log->info($summary); }

    emit_content($dev_id, $out, $out_file,
		 "listing of $zero_count zero-byte backup(s) (out of $count total)", $summary);

    exit($zero_count > 0 ? 1 : 0);
}

#
# Same check as check_zero_backups(), but across every device known
# from the currently loaded -devices=/-line= sources, instead of
# just one. Each output line is prefixed with the device id, so
# multiple devices' zero-byte backups can be told apart:
#   <dev_id>\t<number>\t<size>\t<path>
# <number> is per-device (1=that device's latest backup, ...), same
# as "-z"/"-l". A device whose repository can't be resolved or
# scanned is logged and skipped, without aborting the whole check.
#
#
# -s: for every loaded device, check that all of its backup files carry
# the same filename suffix (the part after the timestamp and optional
# timezone token). Reports each device whose backups mix suffixes -
# including "some with a suffix, some without", which is what happens
# when filename_append_suffix is added or changed after backups already
# exist. Exits 1 if any device is inconsistent, 0 otherwise (same
# convention as -z/-Z/-o). Honours -f like the other lookup modes.
#
# Filename format (see Abstract::dump_config):
#   <dev_id>.run.YYYYMMDD.HHMMSS<tz><suffix>
# where <tz> is "+0200"/"-0500" (strftime %z), or "-BRST"/"-CEST" on
# platforms without %z (a "-" and a timezone NAME), or empty with
# timezone=hide; and <suffix> is the filename_append_suffix, which
# since 9.55 must start with ".". A tz name is uppercase letters and a
# suffix starts with ".", so the two cannot be confused.
#

sub check_suffix_consistency {
    my ($out_file, $only_dev_id) = @_;

    # -s dev_id: one device; -S: every loaded device. An unknown dev_id
    # is caught by scan_backups() below (it logs "unknown device" and
    # returns nothing), exactly as -z handles it.
    my @dev_ids;
    if (defined($only_dev_id)) {
	@dev_ids = ($only_dev_id);
    }
    else {
	@dev_ids = fetchconfig::model::Detector->device_ids;
	if (@dev_ids < 1) {
	    $log->error("no devices loaded (check -devices=/-line=)");
	    exit 1;
	}
    }

    my $out = '';

    my $dev_count     = 0;
    my $total_backups = 0;
    my $inconsistent  = 0;   # devices whose backups mix suffixes
    my $mismatch      = 0;   # consistent devices whose suffix != configured filename_append_suffix

    foreach my $dev_id (@dev_ids) {
	++$dev_count;

	my ($files_ref, $dir_tab_ref) = scan_backups($dev_id);

	if (!defined($files_ref)) {
	    exit 1 if defined($only_dev_id);   # -s dev_id: unknown device / scan error is fatal, like -z
	    next;                              # -S: error already logged; skip this device
	}

	my @files = @$files_ref;
	$total_backups += @files;

	my %count;   # suffix => number of files
	my %example; # suffix => one example filename

	foreach my $file (@files) {
	    # The parser separates the tz token (which changes with DST and
	    # by platform - CET/CEST on AIX, "W. Europe Standard Time" on
	    # Windows, +0200 on Linux) from the suffix, so a DST change is
	    # NOT reported as a suffix change.
	    my ($ts, $tz, $sfx) = fetchconfig::model::Abstract::parse_backup_filename($dev_id, $file);
	    if (!defined($ts)) {
		$log->error("dev=$dev_id: backup filename does not match the expected format, skipping: $file");
		next;
	    }
	    $count{$sfx}++;
	    $example{$sfx} = $file unless exists $example{$sfx};
	}

	if ((keys %count) > 1) {
	    # Step 1 failed: mixed suffixes. Report and do NOT check this
	    # device against the configured suffix (there is no single
	    # suffix to compare).
	    ++$inconsistent;
	    foreach my $sfx (sort { $count{$b} <=> $count{$a} || $a cmp $b } keys %count) {
		my $label = length($sfx) ? $sfx : '(none)';
		$out .= sprintf("%s\t%s\t%d\t%s\n", $dev_id, $label, $count{$sfx}, $example{$sfx});
	    }
	    next;
	}

	# Step 2 (-s dev_id ONLY; -S stays a pure consistency check): the
	# backups are consistent (one suffix, or none) - does that suffix
	# match the filename_append_suffix configured for the device in
	# the device table? No backups at all: nothing to contradict the
	# configuration, counts as a match.
	next unless defined($only_dev_id);
	next unless %count;

	my ($used) = keys %count;
	my $info = fetchconfig::model::Detector->device_info($dev_id);
	my $configured = $info->{model}->dev_option($info->{dev_opt_tab}, "filename_append_suffix");
	$configured = '' unless defined($configured);

	if ($used ne $configured) {
	    ++$mismatch;
	    my $u = length($used)       ? "\"$used\""       : '(none)';
	    my $c = length($configured) ? "\"$configured\"" : '(none)';
	    $log->info("warning: dev=$dev_id: configured filename_append_suffix $c does not match the backup file suffix $u ($count{$used} backup(s), e.g. $example{$used})");
	}
    }

    # Summary line and exit status.
    my $head = "checked $dev_count device(s)/$total_backups backup(s)";
    my ($summary, $rc);
    if (!defined($only_dev_id)) {
	# -S: pure consistency check, exit 0/1 (both summaries at info).
	if ($inconsistent > 0) {
	    $summary = "$head, found $inconsistent device(s) with inconsistent backup suffixes";
	    $rc = 1;
	}
	else {
	    $summary = "$head, backup suffixes are consistent";
	    $rc = 0;
	}
    }
    elsif ($inconsistent > 0) {
	# -s dev_id: inconsistent, so the configured suffix was not checked.
	$summary = "$head, found $inconsistent device(s) with inconsistent backup suffixes, not checked against the configured suffix";
	$rc = 1;
    }
    elsif ($mismatch > 0) {
	$summary = "$head, backup suffixes are consistent, configured suffix does not match the backup file suffixes";
	$rc = 2;
    }
    else {
	$summary = "$head, backup suffixes are consistent, configured suffix matches backup file suffixes";
	$rc = 0;
    }
    $log->info($summary);

    emit_content(defined($only_dev_id) ? $only_dev_id : 'ALL', $out, $out_file,
		 "backup suffix report: $inconsistent inconsistent device(s)" . (defined($only_dev_id) ? ", $mismatch configured-suffix mismatch(es)" : "") . " across $dev_count device(s) ($total_backups backup(s) total); columns: dev_id, suffix, count, example",
		 $summary);

    exit($rc);
}

sub check_zero_backups_all {
    my ($out_file) = @_;

    my @dev_ids = fetchconfig::model::Detector->device_ids;

    if (@dev_ids < 1) {
	$log->error("no devices loaded (check -devices=/-line=)");
	exit 1;
    }

    my $out = '';

    my $dev_count     = 0;
    my $total_backups = 0;
    my $total_zero    = 0;

    foreach my $dev_id (@dev_ids) {
	++$dev_count;

	my ($files_ref, $dir_tab_ref) = scan_backups($dev_id);

	next unless defined($files_ref); # error already logged; skip this device

	my @files   = @$files_ref;
	my %dir_tab = %$dir_tab_ref;

	$total_backups += @files;

	my $index = 0;

	foreach my $file (@files) {
	    ++$index;

	    my $dir  = $dir_tab{$file};
	    my $path = "$dir/$file";

	    my $size = (stat($path))[7];

	    if (!defined($size)) {
		$log->error("dev=$dev_id: could not stat backup file: $path: $!");
		next;
	    }

	    next if ($size != 0);

	    ++$total_zero;

	    $out .= sprintf("%s\t%d\t%s\t%s\n", $dev_id, $index, $size, $path);
	}
    }

    my $summary = ($total_zero > 0)
	? "checked $dev_count device(s)/$total_backups backup(s), found $total_zero zero-byte backup(s)"
	: "checked $dev_count device(s)/$total_backups backup(s), no zero-byte backups found";
    if ($total_zero > 0) { $log->debug($summary); } else { $log->info($summary); }

    emit_content('ALL', $out, $out_file,
		 "listing of $total_zero zero-byte backup(s) across $dev_count device(s) ($total_backups backup(s) total)", $summary);

    exit($total_zero > 0 ? 1 : 0);
}

#
# Recursively walks $dir_path looking for "device directories": any
# directory whose own files include at least one matching
# "<dirname>.run." - the naming convention dump_config() (see
# Abstract.pm) uses for every backup file, under a same-named
# directory. A device can have more than one such directory (one per
# date it was backed up on: .../YYYYMM/YYYYMMDD/<dev_id>/...), so
# results are collected into $found_ref as:
#   <dev_id-like dir name> => [ { path => ..., files => [...] }, ... ]
# Errors (an unreadable directory) are logged and that subtree is
# skipped, without aborting the rest of the scan.
#
sub scan_repo_for_backup_dirs {
    my ($dir_path, $found_ref) = @_;

    local *DIR;

    if (!opendir(DIR, $dir_path)) {
	$log->error("could not open dir: $dir_path: $!");
	return;
    }

    my @entries = readdir(DIR);

    if (!closedir(DIR)) {
	$log->error("could not close dir: $dir_path: $!");
    }

    my ($basename) = $dir_path =~ m{([^/]+)/?$};
    $basename = '' unless defined($basename);

    my @backup_files;

    foreach my $entry (@entries) {
	next if $entry =~ /^\./;

	my $full = "$dir_path/$entry";

	next unless -f $full;

	push @backup_files, $full if ($entry =~ /^\Q$basename\E\.run\./);
    }

    if (@backup_files) {
	# This directory itself holds backup files named after it -
	# it's a device directory, not a date directory. Don't
	# recurse further into it (its own files aren't directories).
	push @{$found_ref->{$basename}}, { path => $dir_path, files => \@backup_files };
	return;
    }

    foreach my $entry (@entries) {
	next if $entry =~ /^\./;

	my $full = "$dir_path/$entry";

	next unless -d $full;

	scan_repo_for_backup_dirs($full, $found_ref);
    }
}

#
# Lists backed up configs found on disk that have no matching
# dev-unique-id in the currently loaded -devices=/-line= sources -
# and, if $delete is set (-D), deletes those orphaned directories too
# ($test, -T, previews the delete commands instead of running them;
# only meaningful together with $delete).
#
# An orphaned backup's own device table entry is, by definition, no
# longer around, so its "repository=" setting can't be looked up
# anymore. Instead, every repository= path configured by a currently
# loaded device is scanned (deduplicated - most fleets share one or a
# few repository paths via a model-wide "default:" line), and any
# device directory found there whose name doesn't match a currently
# known dev_id is reported. A device using a repository path not
# shared by any currently loaded device wouldn't be found this way -
# an inherent limit of "repository" being a per-device setting rather
# than a global one.
#
# Output (tab-separated), one line per orphaned device directory (a
# device can have more than one, across different dates):
#   <dev_id-like name>\t<file count>\t<total bytes>\t<path>
# Written to $out_file if given, or stdout otherwise - this listing
# is the same with or without -D/-T, so a script parsing it doesn't
# need to care which mode produced it. What -D actually does (or, in
# -T mode, would do) is logged separately (to stderr): one "deleting:
# rm <file>"/"would delete: rm <file>" line per backup file (each
# file named explicitly, never a wildcard), followed by one
# "deleting: rmdir <path>"/"would delete: rmdir <path>" line for the
# now-empty directory. No shell command is actually spawned (avoiding
# shell-quoting/injection concerns and, per policy, any use of
# "rm -rf" or a wildcarded delete) - deletion is done file-by-file
# with Perl's own unlink(), then rmdir() on the directory, which only
# succeeds if it's genuinely empty; anything left behind unexpectedly
# (a file this scan didn't account for) makes it fail loudly instead
# of being swept away regardless.
#
# Exit status:
#   plain -o (no -D):        1 if any orphaned backups were found, 0 otherwise
#   -o -D -T (preview only): 1 if any orphaned backups were found, 0 otherwise
#   -o -D (deleting for real): 1 if any deletion failed, 0 otherwise
#      (0 both when nothing needed deleting and when everything found
#      was deleted successfully)
#
#
# Repository paths configured by the currently loaded devices, unique,
# sorted. Shared by -o and -e.
#
sub configured_repositories {
    my %seen;
    foreach my $dev_id (fetchconfig::model::Detector->device_ids) {
	my $info = fetchconfig::model::Detector->device_info($dev_id);
	next unless defined($info);
	my $repo = $info->{model}->dev_option($info->{dev_opt_tab}, "repository");
	$seen{$repo} = 1 if defined($repo) && length($repo);
    }
    sort keys %seen;
}

#
# True if $dir contains no entries other than "." and "..". Unreadable
# directories count as NOT empty (we never delete what we cannot see).
#
sub dir_is_empty {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return 0;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    return @entries == 0;
}

#
# The one and only way a directory is removed by the maintenance modes:
# a single rmdir on ONE explicit, fully-qualified path. No wildcards, no
# recursion. rmdir cannot remove a non-empty directory - the OS refuses -
# so even a logic error here cannot take files with it. Every command is
# reported on stderr ("deleting: rmdir <path>"; with $test, "would
# delete: rmdir <path>" and nothing is done). Returns 1 on success (or in
# test mode), 0 on failure (logged).
#
sub safe_rmdir {
    my ($path, $test) = @_;

    if ($test) {
	$log->info("would delete: rmdir $path");
	return 1;
    }

    $log->info("deleting: rmdir $path");
    if (!rmdir($path)) {
	$log->error("rmdir failed: $path: $!");
	return 0;
    }
    return 1;
}

#
# After a device directory under <repo>/YYYYMM/YYYYMMDD/ has been
# removed, take away the now-empty day directory and then the now-empty
# month directory - each with one plain rmdir, each only if empty, each
# reported. Used by -o -D so that orphan cleanup does not leave empty
# date directories behind (the cause of leftovers such as
# 201501/20150122). Returns the number of directories removed.
#
sub prune_empty_parents {
    my ($dev_dir, $test) = @_;

    my $removed = 0;
    my @labels = split m{/}, $dev_dir;
    pop @labels;                         # -> YYYYMMDD
    my $day = join('/', @labels);
    pop @labels;                         # -> YYYYMM
    my $month = join('/', @labels);

    # Only prune directories that look like what they must be.
    # (Bind the names to variables first: "(split ...)[-1] =~ /re/"
    # parses as an index expression, not a match on the element.)
    my $day_label   = (split m{/}, $day)[-1];
    my $month_label = (split m{/}, $month)[-1];
    return 0 unless defined($day_label)   && $day_label   =~ /^\d{8}$/;
    return 0 unless defined($month_label) && $month_label =~ /^\d{6}$/;

    # Real mode: the device dir is already gone, so plain emptiness.
    # Test mode: the device dir still exists, so "empty" means "the
    # device dir is its only entry" (and likewise one level up).
    my $dev_name = (split m{/}, $dev_dir)[-1];
    my $day_name = (split m{/}, $day)[-1];
    my $day_empty = $test ? _only_entry_is($day, $dev_name) : dir_is_empty($day);

    if (-d $day && $day_empty) {
	$removed++ if safe_rmdir($day, $test);
	if (-d $month) {
	    my $month_empty = $test ? _only_entry_is($month, $day_name) : dir_is_empty($month);
	    $removed++ if $month_empty && safe_rmdir($month, $test);
	}
    }
    return $removed;
}

sub _only_entry_is {
    my ($dir, $name) = @_;
    opendir(my $dh, $dir) or return 0;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    return @entries == 1 && $entries[0] eq $name;
}

#
# -e: scan every configured repository for empty directories in the
# three-level layout <repo>/YYYYMM/YYYYMMDD/<dev_id>/ and list them;
# -e -D removes them, bottom-up: device dirs, then day dirs that are (by
# then) empty, then month dirs that are (by then) empty. -e -D -T lists
# the delete commands without deleting (equivalent to -e in effect).
#
# Only names of the expected shape are ever candidates - ^\d{6}$ for a
# month, ^\d{8}$ whose first six digits equal the month for a day, and
# a dev_id-shaped name (letters, digits, _ . -, not dots-only) for a
# device dir. Anything else, and the repository root itself, is never
# touched. Empty means "no entries but . and .."; a directory that
# cannot be read is treated as not empty.
#
# Output rows (tab-separated): <level>\t<path>[\t<deleted|would-delete|failed>]
# where <level> is device / day / month. Exit: -e -> 1 if any empty
# directory was found, 0 otherwise; -e -D -> 1 if any rmdir failed, 0
# otherwise.
#
sub check_empty_dirs {
    my ($out_file, $delete, $test) = @_;

    my @repos = configured_repositories();
    if (@repos < 1) {
	$log->error("no repository configured by any loaded device (check -devices=/-line=)");
	exit 1;
    }

    my $out = '';
    my ($n_dev, $n_day, $n_month, $n_fail) = (0, 0, 0, 0);

    # Bottom-up, one repository at a time. We evaluate emptiness of a
    # level AFTER the level below it has been processed, so a day
    # directory whose only content was an empty device directory is
    # correctly seen as empty. In -e (scan) and -T modes nothing is
    # removed, so "would be empty after the lower level goes" is
    # computed from the names we already decided to remove.
    foreach my $repo (@repos) {
	opendir(my $rh, $repo) or do { $log->error("cannot read repository $repo: $!"); next; };
	my @months = sort grep { /^\d{6}$/ && -d "$repo/$_" } readdir($rh);
	closedir($rh);

	foreach my $m (@months) {
	    my $mdir = "$repo/$m";
	    opendir(my $mh, $mdir) or do { $log->error("cannot read $mdir: $!"); next; };
	    my @days = sort grep { /^\d{8}$/ && substr($_, 0, 6) eq $m && -d "$mdir/$_" } readdir($mh);
	    closedir($mh);

	    my %day_gone;    # day name => 1 if removed / would be removed

	    foreach my $d (@days) {
		my $ddir = "$mdir/$d";
		opendir(my $dh, $ddir) or do { $log->error("cannot read $ddir: $!"); next; };
		my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
		closedir($dh);

		my %dev_gone;
		foreach my $e (sort @entries) {
		    my $edir = "$ddir/$e";
		    next unless -d $edir;
		    next unless $e =~ /^[A-Za-z0-9][\w.-]*$/;   # dev_id shape: starts alphanumeric, no leading dot
		    next unless dir_is_empty($edir);
		    $n_dev++;
		    if ($delete) {
			my $ok = safe_rmdir($edir, $test);
			$n_fail++ unless $ok;
			$dev_gone{$e} = 1 if $ok;
			$out .= "device\t$edir\t" . ($ok ? ($test ? 'would-delete' : 'deleted') : 'failed') . "\n";
		    }
		    else {
			$dev_gone{$e} = 1;
			$out .= "device\t$edir\n";
		    }
		}

		# Day dir empty now (or would be, once the empty device dirs go)?
		my @remaining = grep { !$dev_gone{$_} } @entries;
		next if @remaining;
		$n_day++;
		if ($delete) {
		    # In test mode the device dirs are still there; rmdir would
		    # fail, so only report.
		    my $ok = safe_rmdir($ddir, $test);
		    $n_fail++ unless $ok;
		    $day_gone{$d} = 1 if $ok;
		    $out .= "day\t$ddir\t" . ($ok ? ($test ? 'would-delete' : 'deleted') : 'failed') . "\n";
		}
		else {
		    $day_gone{$d} = 1;
		    $out .= "day\t$ddir\n";
		}
	    }

	    # Month dir empty now (or would be)? Consider ALL entries, not just
	    # well-formed day dirs: an unexpected file keeps the month.
	    opendir($mh, $mdir) or next;
	    my @mentries = grep { $_ ne '.' && $_ ne '..' } readdir($mh);
	    closedir($mh);
	    my @mremaining = grep { !$day_gone{$_} } @mentries;
	    next if @mremaining;
	    $n_month++;
	    if ($delete) {
		my $ok = safe_rmdir($mdir, $test);
		$n_fail++ unless $ok;
		$out .= "month\t$mdir\t" . ($ok ? ($test ? 'would-delete' : 'deleted') : 'failed') . "\n";
	    }
	    else {
		$out .= "month\t$mdir\n";
	    }
	}
    }

    my $total = $n_dev + $n_day + $n_month;
    my $nrepos = scalar(@repos);
    my ($summary, $rc);
    if ($delete && $test) {
	# Preview: same exit as plain -e (1 if anything was found), matching
	# -o -D -T, so a script can still tell "there is work to do".
	$summary = "(-T) checked $nrepos repository/repositories, found $total empty director" . ($total == 1 ? 'y' : 'ies') . " ($n_dev device, $n_day day, $n_month month) - showing delete commands only, nothing deleted";
	$log->info($summary); $rc = $total ? 1 : 0;
    }
    elsif ($delete) {
	$summary = "checked $nrepos repository/repositories, removed " . ($total - $n_fail) . " of $total empty director" . ($total == 1 ? 'y' : 'ies') . " ($n_dev device, $n_day day, $n_month month)" . ($n_fail ? ", $n_fail failed" : "");
	if ($n_fail) { $log->error($summary); } else { $log->info($summary); }
	$rc = $n_fail ? 1 : 0;
    }
    else {
	$summary = $total
	    ? "checked $nrepos repository/repositories, found $total empty director" . ($total == 1 ? 'y' : 'ies') . " ($n_dev device, $n_day day, $n_month month) - use -e -D to delete them"
	    : "checked $nrepos repository/repositories, no empty directories found";
	$log->info($summary); $rc = $total ? 1 : 0;
    }

    emit_content('ALL', $out, $out_file,
		 "listing of $total empty director" . ($total == 1 ? 'y' : 'ies') . " across $nrepos repository/repositories; columns: level, path" . ($delete ? ", result" : ""),
		 $summary);

    exit($rc);
}

sub check_orphaned_backups {
    my ($out_file, $delete, $test) = @_;

    my @dev_ids = fetchconfig::model::Detector->device_ids;

    if (@dev_ids < 1) {
	$log->error("no devices loaded (check -devices=/-line=)");
	exit 1;
    }

    my %known_dev_id = map { $_ => 1 } @dev_ids;

    my %repo_seen;

    foreach my $dev_id (@dev_ids) {
	my $info = fetchconfig::model::Detector->device_info($dev_id);

	next unless defined($info);

	my $mod         = $info->{model};
	my $dev_opt_tab = $info->{dev_opt_tab};

	my $dev_repository = $mod->dev_option($dev_opt_tab, "repository");

	next unless defined($dev_repository);

	$repo_seen{$dev_repository} = 1;
    }

    my @repos = sort keys %repo_seen;

    if (@repos < 1) {
	$log->error("no repository configured for any loaded device");
	exit 1;
    }

    my %found; # dev_id-like dir name => [ { path, files }, ... ]

    foreach my $repo (@repos) {
	if (! -d $repo) {
	    $log->error("repository is not a directory: $repo");
	    next;
	}
	scan_repo_for_backup_dirs($repo, \%found);
    }

    my %repo_root = map { $_ => 1 } @repos;

    my $out = '';

    my $orphan_dirs     = 0;
    my $orphan_files    = 0;
    my $delete_failures = 0;

    foreach my $name (sort keys %found) {
	next if $known_dev_id{$name}; # matches a currently loaded device - not an orphan

	foreach my $entry (@{$found{$name}}) {
	    ++$orphan_dirs;

	    my @files = @{$entry->{files}};

	    $orphan_files += @files;

	    my $total_size = 0;
	    foreach my $file (@files) {
		my $size = (stat($file))[7];
		$total_size += $size if defined($size);
	    }

	    $out .= sprintf("%s\t%d\t%d\t%s\n", $name, scalar(@files), $total_size, $entry->{path});

	    next unless $delete;

	    my $path = $entry->{path};

	    # Belt-and-suspenders: scan_repo_for_backup_dirs() only ever
	    # records a directory here because it directly holds backup
	    # files named after itself, so this "should" be impossible -
	    # but this is a destructive operation, so never proceed if
	    # the path to remove is, or is above, a repository root.
	    if ($repo_root{$path} || grep { index($_, "$path/") == 0 } @repos) {
		$log->error("refusing to delete what looks like a repository root: $path");
		++$delete_failures;
		next;
	    }

	    # Delete each backup file individually by its exact name (no
	    # wildcards, no recursive "rm -rf"/"rmdir /s"), then remove
	    # the now-empty directory separately. rmdir only succeeds on
	    # an empty directory, so anything left behind unexpectedly
	    # (a file this scan didn't account for) makes it fail loudly
	    # instead of being silently swept away.
	    if ($test) {
		foreach my $file (@files) {
		    $log->info("would delete: rm $file");
		}
		$log->info("would delete: rmdir $path");
		# and the day/month directories that would become empty
		prune_empty_parents($path, 1);
		next;
	    }

	    my $dir_ok = 1;

	    foreach my $file (@files) {
		$log->info("deleting: rm $file");

		if (!unlink($file)) {
		    $log->error("could not delete file: $file: $!");
		    ++$delete_failures;
		    $dir_ok = 0;
		}
	    }

	    if (!$dir_ok) {
		$log->error("not removing directory (not all its files could be deleted): $path");
		next;
	    }

	    $log->info("deleting: rmdir $path");

	    if (!rmdir($path)) {
		$log->error("could not delete directory: $path: $!");
		++$delete_failures;
		next;
	    }

	    # Take away the day and month directories this leaves empty, so
	    # orphan cleanup does not accumulate empty date directories (see
	    # -e). One plain rmdir each, only if empty, each reported.
	    prune_empty_parents($path, 0);
	}
    }

    my $nrepos = scalar(@repos);
    my $summary;
    if ($delete) {
	if ($test) {
	    $summary = "(-T) checked $nrepos repository/repositories, found $orphan_dirs orphaned device dir(s)/$orphan_files backup file(s) - showing delete commands only, nothing deleted";
	    $log->info($summary);
	}
	elsif ($delete_failures > 0) {
	    $summary = "checked $nrepos repository/repositories, found $orphan_dirs orphaned device dir(s), $delete_failures failed to delete";
	    $log->error($summary);
	}
	else {
	    $summary = "checked $nrepos repository/repositories, found $orphan_dirs orphaned device dir(s), all deleted";
	    $log->info($summary);
	}
    }
    elsif ($orphan_dirs > 0) {
	$summary = "checked $nrepos repository/repositories, found $orphan_dirs orphaned device dir(s)/$orphan_files backup file(s)";
	$log->debug($summary);
    }
    else {
	$summary = "checked $nrepos repository/repositories, no orphaned backups found";
	$log->info($summary);
    }

    emit_content('ALL', $out, $out_file,
		 "listing of $orphan_dirs orphaned device dir(s) ($orphan_files backup file(s) total)", $summary);

    exit(($delete && !$test) ? ($delete_failures > 0 ? 1 : 0) : ($orphan_dirs > 0 ? 1 : 0));
}

1;

#! /usr/bin/perl -w
#
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
# $Id: fetchconfig.pl,v 9.8 2026/08/26 12:00:00 tammer Exp $

use FindBin qw($Bin);
use strict;

use lib "$FindBin::Bin/";

use fetchconfig::Logger;
use fetchconfig::Constants;
use fetchconfig::Mailer;
use fetchconfig::model::Detector;

sub basename {
    my ($path) = @_;

    my @list;

    if ($^O eq 'MSWin32') {
	@list = split /\\/, $path;
    }
    else {
	@list = split /\//, $path;
    }

    pop @list;
}

my $me = basename($0);

my $log = fetchconfig::Logger->new({ prefix => $me });

$log->info('-----[fetchconfig]--------------------------------------------------------------------------------');
$log->info('version ' . fetchconfig::Constants::version);

my @device_file_list;
my @line_list;   # set by -line=: device table line(s) given directly on the command line

my $retrieve_dev_id;   # set by -g: enables config retrieval mode
my $retrieve_index = 1; # set by -n: 1 = latest, 2 = next most recent, ...
my $compare_index;      # set by -m: enables compare mode against -n
my $list_dev_id;        # set by -l: enables backup listing mode
my $zero_check_dev_id;  # set by -z: enables zero-byte backup check mode (single device)
my $zero_check_all;     # set by -Z: enables zero-byte backup check mode (all loaded devices)
my $suffix_check_dev_id; # set by -s: checks one device for inconsistent backup filename suffixes
my $suffix_check_all;    # set by -S: same, for every loaded device
my $orphan_check;       # set by -o: enables orphaned backup check mode
my $empty_check;        # set by -e: enables empty-directory check mode
my $orphan_delete;      # set by -D: also delete what -o (orphaned backups) or -e (empty directories) found (requires -o or -e)
my $orphan_test;        # set by -T: with -D, only show what would be deleted, don't delete (requires -D)
my $retrieve_out_file;  # set by -f: optional output file (default: stdout)
my $parallel = 1;       # set by -P N: number of concurrent fetch workers (1 = sequential, the default)

my $i = 0;

while ($i <= $#ARGV) {
    my $opt = $ARGV[$i];

    if ($opt eq '-v') {
	exit; # only show version
    }

    # Help requested deliberately: print the usage to STDOUT and exit 0.
    # (Before 9.55 "-?" fell through to the unknown-argument branch,
    # which logged an error, printed usage to stderr and then die()d,
    # ending with a spurious "Died at ... line N".)
    if ($opt eq '-?' || $opt eq '-h' || $opt eq '--help') {
	&usage_stdout;
	exit 0;
    }

    if ($opt =~ /^-devices=(.+)$/) {
	push @device_file_list, $1;
	++$i;
	next;
    }

    if ($opt =~ /^-line=(.+)$/) {
	push @line_list, $1;
	++$i;
	next;
    }

    if ($opt eq '-g') {
	$retrieve_dev_id = $ARGV[$i + 1];
	if (!defined($retrieve_dev_id)) {
	    $log->error("-g requires a device id/hostname argument");
	    &usage;
	    die;
	}
	$i += 2;
	next;
    }

    if ($opt eq '-l') {
	$list_dev_id = $ARGV[$i + 1];
	if (!defined($list_dev_id)) {
	    $log->error("-l requires a device id/hostname argument");
	    &usage;
	    die;
	}
	$i += 2;
	next;
    }

    if ($opt eq '-z') {
	$zero_check_dev_id = $ARGV[$i + 1];
	if (!defined($zero_check_dev_id)) {
	    $log->error("-z requires a device id/hostname argument");
	    &usage;
	    die;
	}
	$i += 2;
	next;
    }

    if ($opt eq '-Z') {
	$zero_check_all = 1;
	++$i;
	next;
    }

    if ($opt eq '-S') {
	$suffix_check_all = 1;
	++$i;
	next;
    }

    if ($opt eq '-s') {
	$suffix_check_dev_id = $ARGV[$i + 1];
	# "-s" takes a dev_id (use "-S" for all devices); also catch "-s -f
	# file" and similar, where the next word is another option.
	if (!defined($suffix_check_dev_id) || $suffix_check_dev_id =~ /^-/) {
	    $log->error("-s requires a device id/hostname argument (use -S to check every device)");
	    &usage;
	    die;
	}
	$i += 2;
	next;
    }

    if ($opt eq '-o') {
	$orphan_check = 1;
	++$i;
	next;
    }

    if ($opt eq '-e') {
	$empty_check = 1;
	++$i;
	next;
    }

    if ($opt eq '-D') {
	$orphan_delete = 1;
	++$i;
	next;
    }

    if ($opt eq '-T') {
	$orphan_test = 1;
	++$i;
	next;
    }

    if ($opt eq '-n') {
	my $n = $ARGV[$i + 1];
	if (!defined($n) || $n !~ /^\d+$/ || $n < 1) {
	    $log->error("-n requires a positive integer argument");
	    &usage;
	    die;
	}
	$retrieve_index = $n;
	$i += 2;
	next;
    }

    if ($opt eq '-m') {
	my $m = $ARGV[$i + 1];
	if (!defined($m) || $m !~ /^\d+$/ || $m < 1) {
	    $log->error("-m requires a positive integer argument");
	    &usage;
	    die;
	}
	$compare_index = $m;
	$i += 2;
	next;
    }

    if ($opt eq '-P') {
	my $n = $ARGV[$i + 1];
	if (!defined($n) || $n !~ /^\d+$/ || $n < 1) {
	    $log->error("-P requires a positive number of parallel workers");
	    &usage;
	    die;
	}
	$parallel = $n;
	$i += 2;
	next;
    }

    if ($opt eq '-f') {
	$retrieve_out_file = $ARGV[$i + 1];
	if (!defined($retrieve_out_file)) {
	    $log->error("-f requires a file argument");
	    &usage;
	    die;
	}
	$i += 2;
	next;
    }

    $log->error("unexpected argument: $opt");
    &usage;
    die;
}

if ((@device_file_list < 1) && (@line_list < 1)) {
    $log->error("at least one -devices=filename or one -line=string is required");
    &usage;
    die;
}

if ((grep { defined($_) } ($retrieve_dev_id, $list_dev_id, $zero_check_dev_id, $zero_check_all, $orphan_check, $empty_check, $suffix_check_dev_id, $suffix_check_all)) > 1) {
    $log->error("-g, -l, -z, -Z, -o, -e, -s and -S are mutually exclusive");
    &usage;
    die;
}

if (defined($compare_index)) {
    if (!defined($retrieve_dev_id)) {
	$log->error("-m requires -g to select a device");
	&usage;
	die;
    }
    if ($compare_index <= $retrieve_index) {
	$log->error("-m ($compare_index) must be higher than -n ($retrieve_index)");
	&usage;
	die;
    }
}

if (defined($orphan_delete) && !defined($orphan_check) && !defined($empty_check)) {
    $log->error("-D requires -o or -e");
    &usage;
    die;
}

if (defined($orphan_test) && !defined($orphan_delete)) {
    $log->error("-T requires -D");
    &usage;
    die;
}

fetchconfig::model::Detector->init($log);

my $lookup_only = defined($retrieve_dev_id) || defined($list_dev_id) || defined($zero_check_dev_id) || defined($zero_check_all) || defined($orphan_check) || defined($empty_check) || defined($suffix_check_dev_id) || defined($suffix_check_all);

if ($parallel > 1 && $lookup_only) {
    $log->error("-P applies to fetching only and cannot be combined with -g/-l/-z/-Z/-o/-e/-s/-S");
    &usage;
    die;
}

foreach my $dev_file (@device_file_list) {
    &load_device_list($dev_file, $lookup_only);
}

my $line_num = 0;
foreach my $line (@line_list) {
    ++$line_num;
    &load_line($line, $line_num, $lookup_only);
}

if (defined($retrieve_dev_id)) {
    if (defined($compare_index)) {
	&compare_config($retrieve_dev_id, $retrieve_index, $compare_index, $retrieve_out_file);
    }
    else {
	&retrieve_config($retrieve_dev_id, $retrieve_index, $retrieve_out_file);
    }
    exit;
}

if (defined($list_dev_id)) {
    &list_backups($list_dev_id, $retrieve_out_file);
    exit;
}

if (defined($zero_check_dev_id)) {
    &check_zero_backups($zero_check_dev_id, $retrieve_out_file);
    exit;
}

if (defined($zero_check_all)) {
    &check_zero_backups_all($retrieve_out_file);
    exit;
}

if (defined($suffix_check_all)) {
    &check_suffix_consistency($retrieve_out_file);
    exit;
}

if (defined($suffix_check_dev_id)) {
    &check_suffix_consistency($retrieve_out_file, $suffix_check_dev_id);
    exit;
}

if (defined($empty_check)) {
    &check_empty_dirs($retrieve_out_file, $orphan_delete, $orphan_test);
    exit;
}

if (defined($orphan_check)) {
    &check_orphaned_backups($retrieve_out_file, $orphan_delete, $orphan_test);
    exit;
}

# Phase 2: fetch every registered device - sequentially (the default,
# device-table order, live output exactly as before), or with -P N
# concurrent worker processes.
&run_fetch_phase($parallel);

fetchconfig::Mailer->send_summaries($log);

$log->info("done");

exit;

#
# Usage text. usage() prints it to STDERR (used on errors, followed by
# die); usage_stdout() prints it to STDOUT and is used for a deliberate
# help request (-?, -h, --help), which exits 0.
#
sub usage_text {
    my $t = '';
    $t .= "usage: $me [-v] [-devices=file] [-line=string] [-P N]\n";
    $t .= "       $me [-devices=file] [-line=string] -g dev_id [-n N] [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -g dev_id -n N -m M [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -l dev_id [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -z dev_id [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -Z [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -s dev_id [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -S [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -o [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -o -D [-T] [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -e [-f file]\n";
    $t .= "       $me [-devices=file] [-line=string] -e -D [-T] [-f file]\n";
    $t .= "\n";
    $t .= "       -devices=file  device table file to load (repeatable)\n";
    $t .= "       -P N           fetch with N parallel worker processes (default 1 = sequential, device-table\n";
    $t .= "                      order, live output). With N>1 each device's output is buffered and shown as one\n";
    $t .= "                      uninterrupted block when it finishes, in completion order; never interleaved.\n";
    $t .= "                      Fetching only - not combinable with -g/-l/-z/-Z/-o/-e/-s/-S. Size N by what the\n";
    $t .= "                      devices tolerate (login limits, AAA rate, links); 10-25 is typical.\n";
    $t .= "       -line=string   a single device table line given directly on the command line (repeatable)\n";
    $t .= "       -g dev_id      retrieve a backed up config for dev_id instead of fetching\n";
    $t .= "       -n N           select which backup to retrieve (1=latest, 2=next most recent, ...); default 1\n";
    $t .= "       -m M           compare backup N against the older backup M (M must be > N); output is a diff\n";
    $t .= "       -l dev_id      list all backed up configs for dev_id (mutually exclusive with -g/-z/-Z/-o)\n";
    $t .= "       -z dev_id      list backed up configs for dev_id that are 0 bytes long (mutually exclusive with -g/-l/-Z/-o);\n";
    $t .= "                      exits 1 if any are found, 0 if all backups are non-empty\n";
    $t .= "       -Z             same as -z, but checks every device loaded via -devices=/-line= (mutually exclusive with -g/-l/-z/-o)\n";
    $t .= "       -s dev_id      check dev_id for inconsistent backup filename suffixes (some backups with a suffix\n";
    $t .= "                      and some without, or differing suffixes) - see filename_append_suffix in the README\n";
    $t .= "                      (mutually exclusive with -g/-l/-z/-Z/-o/-e/-S); also compares the suffix the backups use\n";
    $t .= "                      against the configured filename_append_suffix. Exit: 0 consistent and matches,\n";
    $t .= "                      1 inconsistent (configured suffix not checked), 2 consistent but does not match\n";
    $t .= "       -S             same as -s, but checks every device loaded via -devices=/-line= (mutually exclusive\n";
    $t .= "                      with -g/-l/-z/-Z/-o/-s); consistency check only (no configured-suffix step);\n";
    $t .= "                      exits 1 if any device is inconsistent, 0 otherwise\n";
    $t .= "       -o             list backed up configs on disk that have no matching device in the currently\n";
    $t .= "                      loaded -devices=/-line= (mutually exclusive with -g/-l/-z/-Z); scans every\n";
    $t .= "                      repository= path configured by a currently loaded device; exits 1 if any\n";
    $t .= "                      orphaned backups are found, 0 otherwise\n";
    $t .= "       -D             with -o: also DELETE the orphaned backup directories found; with -e: also DELETE\n";
    $t .= "                      the empty directories found (requires -o or -e)\n";
    $t .= "       -T             with -o -D or -e -D: only show the delete commands, don't actually delete anything\n";
    $t .= "                      (requires -D) - use this first to preview what -D would remove; exit status is that\n";
    $t .= "                      of the plain check (-o / -e), i.e. 1 if anything was found\n";
    $t .= "       -e             list empty directories in every configured repository= path, in the\n";
    $t .= "                      <repo>/YYYYMM/YYYYMMDD/<dev_id>/ layout (mutually exclusive with -g/-l/-z/-Z/-o/-s/-S);\n";
    $t .= "                      exits 1 if any are found, 0 otherwise. With -D they are removed bottom-up - device\n";
    $t .= "                      dirs, then day dirs, then month dirs - each by one plain rmdir on its exact path, every\n";
    $t .= "                      command reported; -T with -e -D shows the commands without deleting\n";
    $t .= "       -f file        write the result data (config/diff/listing rows) to file instead of stdout; log\n";
    $t .= "                      messages still go to stderr. A check that finds nothing writes an EMPTY file -\n";
    $t .= "                      that is the expected result; the outcome is in the exit status\n";
    $t .= "       -?, -h, --help display this help and exit\n";
    $t;
}

sub usage {
    warn usage_text();
}

sub usage_stdout {
    print usage_text();
}

#
# Phase 2 driver. -P 1: plain loop over the devices in device-table
# order; every device's output streams live, as in every earlier
# version. -P N>1: a pool of N forked workers.
#
# Concurrency design (see README, PARALLEL FETCHING):
#  - The parent hands out ONE device at a time over a pipe to whichever
#    worker asks next, so a slow device never holds up a batch.
#  - Each worker is a fork of the fully loaded parent (models, device
#    table, options), so fetch_device() runs unchanged; nothing per
#    model had to be touched. Net::OpenSSH masters are per process.
#  - Output is ATOMIC PER DEVICE: while a worker fetches, its STDOUT
#    and STDERR are redirected into two per-device temporary files;
#    nothing reaches the real streams. When the device is done, the
#    worker tells the parent, and the PARENT alone copies the two
#    buffers to the real STDOUT/STDERR in one uninterrupted block. A
#    device's lines are therefore never interleaved with another's.
#    Blocks appear in completion order (not table order).
#  - Results: Mailer::record_result keeps its rows in-process, which a
#    worker cannot share. fetch_device() therefore runs with a hook
#    that makes record_result write the row to a per-device result
#    file instead; the parent reads it back and calls record_result
#    itself, so send_summaries, per-device to= bundling and the .status
#    file all happen in the parent exactly as before.
#  - A worker that dies (perl error, signal, OOM) is noticed through
#    waitpid; the device it held is recorded as failed so the mail and
#    status file still account for it.
#  - The repository is safe under concurrency: every device writes its
#    own <dev_id> directory, .status and .debug; only the shared date
#    directories are created by several workers, and make_path
#    tolerates an existing directory.
#
sub run_fetch_phase {
    my ($workers) = @_;

    my @devs = fetchconfig::model::Detector->device_ids_in_order;

    if ($workers <= 1) {
	foreach my $dev_id (@devs) {
	    fetchconfig::model::Detector->fetch_device($dev_id);
	}
	return;
    }

    $workers = scalar(@devs) if $workers > @devs && @devs > 0;
    $log->info("fetching " . scalar(@devs) . " device(s) with $workers parallel worker(s); output is shown per device, in completion order");

    require File::Temp;
    my $tmpdir = File::Temp::tempdir("fetchconfig-P-XXXXXX", TMPDIR => 1, CLEANUP => 1);

    # Work distribution: the parent writes dev_ids into one shared pipe;
    # workers read one line each. Each dev_id line is shorter than
    # PIPE_BUF, so a line is read whole by exactly one worker.
    pipe(my $work_r, my $work_w) or die "pipe: $!";
    # Completion notifications: workers -> parent, one line per device
    # ("<dev_id>\t<status>").
    pipe(my $done_r, my $done_w) or die "pipe: $!";
    $done_w->autoflush(1); $work_w->autoflush(1);

    my %child;        # pid => 1
    my %holding;      # pid => dev_id currently being fetched (for crash accounting)

    my $shutdown = 0;
    local $SIG{INT} = local $SIG{TERM} = sub { $shutdown = 1; kill 'TERM', keys %child; };

    for my $w (1 .. $workers) {
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if ($pid == 0) {
	    # ---- worker ----
	    close $work_w; close $done_r;
	    $SIG{INT} = $SIG{TERM} = 'DEFAULT';
	    while (defined(my $dev_id = <$work_r>)) {
		chomp $dev_id;
		last if $dev_id eq '';
		my $base = "$tmpdir/$dev_id";
		# announce which device we hold (crash accounting), then
		# buffer all output for this device
		print $done_w "$dev_id\tstart\n";
		open(my $save_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
		open(my $save_err, '>&', \*STDERR) or die "dup STDERR: $!";
		open(STDOUT, '>', "$base.out") or die "open $base.out: $!";
		open(STDERR, '>', "$base.err") or die "open $base.err: $!";
		STDOUT->autoflush(1); STDERR->autoflush(1);
		# results go to a file for the parent to replay
		fetchconfig::Mailer->set_result_sink("$base.res");
		eval { fetchconfig::model::Detector->fetch_device($dev_id); 1 }
		    or print STDERR "fetchconfig.pl: error: dev=$dev_id: worker exception: $@";
		fetchconfig::Mailer->set_result_sink(undef);
		open(STDOUT, '>&', $save_out); open(STDERR, '>&', $save_err);
		print $done_w "$dev_id\tdone\n";
	    }
	    exit 0;
	}
	$child{$pid} = 1;
    }
    close $work_r; close $done_w;

    # Feed the queue, then close it so idle workers exit.
    print $work_w "$_\n" for @devs;
    close $work_w;

    # Collect completions and replay each device's buffered output as
    # one block. Also learn which worker holds which device.
    my %pending = map { $_ => 1 } @devs;
    my %started;
    while (%pending) {
	my $line = <$done_r>;
	if (!defined($line)) { last; }          # all workers gone
	chomp $line;
	my ($dev_id, $what) = split /\t/, $line, 2;
	if ($what eq 'start') { $started{$dev_id} = 1; next; }
	replay_device_block($tmpdir, $dev_id);
	delete $pending{$dev_id};
    }

    # Reap workers; a non-zero exit means one died mid-device.
    for my $pid (keys %child) {
	waitpid($pid, 0);
	if ($? != 0) {
	    $log->error("fetch worker pid=$pid exited abnormally (status " . ($? >> 8) . ", signal " . ($? & 127) . ")");
	}
    }

    # Any device that was started but never finished belonged to a
    # crashed worker: replay what it produced and record it as failed.
    for my $dev_id (sort keys %pending) {
	replay_device_block($tmpdir, $dev_id);
	my $info = fetchconfig::model::Detector->device_info($dev_id);
	$log->error("dev=$dev_id: fetch did not complete (worker died) - recorded as failed");
	fetchconfig::Mailer->record_result(
	    dev_id       => $dev_id,
	    dev_host     => $info ? $info->{dev_host} : '',
	    ts           => time,
	    elapsed      => 0,
	    repository   => $info ? $info->{model}->dev_option($info->{dev_opt_tab}, "repository") : undef,
	    changes_only => $info ? $info->{model}->dev_option($info->{dev_opt_tab}, "changes_only") : undef,
	    success      => 0,
	    size         => undef,
	    changed      => 'n/a',
	    to           => $info ? $info->{dev_opt_tab}->{to} : undef,
	    );
    }
}

#
# Copies a device's buffered STDERR and STDOUT to the real streams as
# one uninterrupted block (STDERR first: the log lines, then any
# on_fetch_cat output on STDOUT), then replays its result rows into
# Mailer::record_result and removes the buffers.
#
sub replay_device_block {
    my ($tmpdir, $dev_id) = @_;
    my $base = "$tmpdir/$dev_id";

    for my $pair (["$base.err", \*STDERR], ["$base.out", \*STDOUT]) {
	my ($file, $fh) = @$pair;
	if (open(my $in, '<', $file)) {
	    local $/;
	    my $data = <$in>;
	    close $in;
	    print {$fh} $data if defined($data) && length($data);
	}
    }
    fetchconfig::Mailer->replay_result_file("$base.res");
    unlink "$base.err", "$base.out", "$base.res";
}

sub load_device_list {
    my ($filename, $lookup_only) = @_;

    local *IN;

    if (!open(IN, '<', $filename)) {
	$log->error("could not read device list: $filename: $!");
	return;
    }

    $log->debug("loading device list: $filename");

    my $line_num = 0;

    while (<IN>) {
	chomp;

	++$line_num;

	#$log->debug("[$line_num] $_");

	next if (/^\s*(#|$)/);

        fetchconfig::model::Detector->parse($filename, $line_num, $_, $lookup_only);
    }

    close IN;
}

sub load_line {
    my ($line, $num, $lookup_only) = @_;

    $log->debug("loading line: line=$num [$line]");

    return if ($line =~ /^\s*(#|$)/);

    fetchconfig::model::Detector->parse('<cmdline>', $num, $line, $lookup_only);
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

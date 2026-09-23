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
use fetchconfig::Tools;
use Getopt::Long qw(GetOptionsFromArray);

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

# Command-line options are parsed with Getopt::Long (core in every Perl).
# fetchconfig has always used single-dash, long-ish option names
# (-devices=, -line=, -P, -g, ...), so Getopt::Long is configured to match
# that exact syntax rather than the GNU "--long" default:
#   no_auto_abbrev  - "-d" must not be accepted as short for "-devices"
#   no_bundling     - "-Ze" is not "-Z -e"
#   no_ignore_case  - -s and -S, -z and -Z are distinct
#   pass_through    - an unknown option is left in @ARGV so we can report it
#                     with the historical "unexpected argument: X" message
#                     and exit 255, exactly as the hand-written loop did.
# -devices= and -line= accumulate (repeatable); -g/-l/-z/-s/-f/-n/-m/-P take
# a value. Getopt::Long accepts both "-g dev" and "-g=dev"; the old loop
# accepted only "-g dev", but "-g=dev" is a harmless superset.
#
# -v (version only) and -h/-?/--help are handled before Getopt::Long so
# their historical behaviour (exit 0, help to STDOUT) is untouched.
for my $a (@ARGV) {
    if ($a eq '-v') { exit 0; }                       # version banner only
    if ($a eq '-h' || $a eq '-?' || $a eq '--help') {
        &usage_stdout;
        exit 0;
    }
}

# A parse or validation failure follows the historical path: log the error,
# print usage to STDERR, and die (which exits 255). Kept in one place.
my $opt_fail = sub {
    my ($msg) = @_;
    $log->error($msg);
    &usage;
    die "\n";
};

Getopt::Long::Configure(qw(no_auto_abbrev no_bundling no_ignore_case pass_through));

my $got = GetOptions(
    'devices=s' => \@device_file_list,
    'line=s'    => \@line_list,
    'g=s'       => \$retrieve_dev_id,
    'l=s'       => \$list_dev_id,
    'z=s'       => \$zero_check_dev_id,
    'Z'         => \$zero_check_all,
    's=s'       => \$suffix_check_dev_id,
    'S'         => \$suffix_check_all,
    'o'         => \$orphan_check,
    'e'         => \$empty_check,
    'D'         => \$orphan_delete,
    'T'         => \$orphan_test,
    'n=s'       => \$retrieve_index,   # validated as a positive integer below
    'm=s'       => \$compare_index,
    'P=s'       => \$parallel,
    'f=s'       => \$retrieve_out_file,
);

# pass_through leaves an unknown option (or a stray word) in @ARGV. Report
# the first one exactly as before. A value that looks like an option (e.g.
# "-s -f out") also lands here, because Getopt::Long will not consume the
# following "-f" as -s's value under these settings - it reports -s as
# missing its argument, which we translate to the historical message.
if (!$got) {
    # GetOptions already warned about the specific problem; map the common
    # "option requires an argument" case to the per-option message.
    $opt_fail->("error parsing command-line options");
}

# Under pass_through, a value-taking option given with no value is left in
# @ARGV untouched (e.g. "... -g" at end of line). Report it with the same
# per-option message the hand-written loop used, before the generic
# unexpected-argument check below.
my %needs_value_msg = (
    '-g' => "-g requires a device id/hostname argument",
    '-l' => "-l requires a device id/hostname argument",
    '-z' => "-z requires a device id/hostname argument",
    '-s' => "-s requires a device id/hostname argument (use -S to check every device)",
    '-f' => "-f requires a file argument",
    '-n' => "-n requires a positive integer argument",
    '-m' => "-m requires a positive integer argument",
    '-P' => "-P requires a positive number of parallel workers",
);
for my $tok (@ARGV) {
    $opt_fail->($needs_value_msg{$tok}) if exists $needs_value_msg{$tok};
}

# -s must take a device id, never an option: "-s -f out" gave -s the value
# "-f" (Getopt::Long consumes the next token), which the old loop rejected.
# Check that before the generic unexpected-argument report so the message
# and order match.
if (defined($suffix_check_dev_id) && ($suffix_check_dev_id eq '' || $suffix_check_dev_id =~ /^-/)) {
    $opt_fail->("-s requires a device id/hostname argument (use -S to check every device)");
}

if (@ARGV) {
    $opt_fail->("unexpected argument: $ARGV[0]");
}

# --- per-option value validation, preserving the old messages/exit code ---
if (defined($retrieve_dev_id) && $retrieve_dev_id eq '') {
    $opt_fail->("-g requires a device id/hostname argument");
}
if (defined($list_dev_id) && $list_dev_id eq '') {
    $opt_fail->("-l requires a device id/hostname argument");
}
if (defined($zero_check_dev_id) && $zero_check_dev_id eq '') {
    $opt_fail->("-z requires a device id/hostname argument");
}
if (defined($suffix_check_dev_id) && ($suffix_check_dev_id eq '' || $suffix_check_dev_id =~ /^-/)) {
    $opt_fail->("-s requires a device id/hostname argument (use -S to check every device)");
}
if (defined($retrieve_out_file) && $retrieve_out_file eq '') {
    $opt_fail->("-f requires a file argument");
}
if ($retrieve_index !~ /^\d+$/ || $retrieve_index < 1) {
    $opt_fail->("-n requires a positive integer argument");
}
if (defined($compare_index) && ($compare_index !~ /^\d+$/ || $compare_index < 1)) {
    $opt_fail->("-m requires a positive integer argument");
}
if ($parallel !~ /^\d+$/ || $parallel < 1) {
    $opt_fail->("-P requires a positive number of parallel workers");
}

if ((@device_file_list < 1) && (@line_list < 1)) {
    $log->error("at least one -devices=filename or one -line=string is required");
    &usage;
    die "\n";
}

if ((grep { defined($_) } ($retrieve_dev_id, $list_dev_id, $zero_check_dev_id, $zero_check_all, $orphan_check, $empty_check, $suffix_check_dev_id, $suffix_check_all)) > 1) {
    $log->error("-g, -l, -z, -Z, -o, -e, -s and -S are mutually exclusive");
    &usage;
    die "\n";
}

if (defined($compare_index)) {
    if (!defined($retrieve_dev_id)) {
	$log->error("-m requires -g to select a device");
	&usage;
	die "\n";
    }
    if ($compare_index <= $retrieve_index) {
	$log->error("-m ($compare_index) must be higher than -n ($retrieve_index)");
	&usage;
	die "\n";
    }
}

if (defined($orphan_delete) && !defined($orphan_check) && !defined($empty_check)) {
    $log->error("-D requires -o or -e");
    &usage;
    die "\n";
}

if (defined($orphan_test) && !defined($orphan_delete)) {
    $log->error("-T requires -D");
    &usage;
    die "\n";
}

fetchconfig::model::Detector->init($log);

my $lookup_only = defined($retrieve_dev_id) || defined($list_dev_id) || defined($zero_check_dev_id) || defined($zero_check_all) || defined($orphan_check) || defined($empty_check) || defined($suffix_check_dev_id) || defined($suffix_check_all);

if ($parallel > 1 && $lookup_only) {
    $log->error("-P applies to fetching only and cannot be combined with -g/-l/-z/-Z/-o/-e/-s/-S");
    &usage;
    die "\n";
}

foreach my $dev_file (@device_file_list) {
    &load_device_list($dev_file, $lookup_only);
}

my $line_num = 0;
foreach my $line (@line_list) {
    ++$line_num;
    &load_line($line, $line_num, $lookup_only);
}

fetchconfig::Tools->init(log => $log, me => $me);

if (defined($retrieve_dev_id)) {
    if (defined($compare_index)) {
	fetchconfig::Tools::compare_config($retrieve_dev_id, $retrieve_index, $compare_index, $retrieve_out_file);
    }
    else {
	fetchconfig::Tools::retrieve_config($retrieve_dev_id, $retrieve_index, $retrieve_out_file);
    }
    exit;
}

if (defined($list_dev_id)) {
    fetchconfig::Tools::list_backups($list_dev_id, $retrieve_out_file);
    exit;
}

if (defined($zero_check_dev_id)) {
    fetchconfig::Tools::check_zero_backups($zero_check_dev_id, $retrieve_out_file);
    exit;
}

if (defined($zero_check_all)) {
    fetchconfig::Tools::check_zero_backups_all($retrieve_out_file);
    exit;
}

if (defined($suffix_check_all)) {
    fetchconfig::Tools::check_suffix_consistency($retrieve_out_file);
    exit;
}

if (defined($suffix_check_dev_id)) {
    fetchconfig::Tools::check_suffix_consistency($retrieve_out_file, $suffix_check_dev_id);
    exit;
}

if (defined($empty_check)) {
    fetchconfig::Tools::check_empty_dirs($retrieve_out_file, $orphan_delete, $orphan_test);
    exit;
}

if (defined($orphan_check)) {
    fetchconfig::Tools::check_orphaned_backups($retrieve_out_file, $orphan_delete, $orphan_test);
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

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
# $Id: Abstract.pm,v 9.11 2026/08/25 12:00:00 tammer Exp $

package fetchconfig::model::Abstract; # fetchconfig/model/Abstract.pm

use strict;
use warnings;
use File::Compare;
use File::Path qw(make_path);
use POSIX qw(strftime);
use Text::ParseWords ();

####################################
# Implement model::Abstract - Begin
#

sub label {
    die "model::Abstract->label: SPECIALIZE ME";
}

sub new {
    my ($class, $log) = @_;

    my $self = {
	log             => $log,
	default_options => {}
    };

    bless $self, $class;
}

sub fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    die "model::Abstract->fetch: SPECIALIZE ME";
}

# chat_banner is used to allow temporary modification
# of timeout throught the 'banner_timeout' option
#
sub chat_banner {
    my ($self, $t, $dev_opt_tab, $login_pattern) = @_;

    my $save_timeout;
    my $banner_timeout = $self->dev_option($dev_opt_tab, "banner_timeout");

    if (defined($banner_timeout)) {
        $save_timeout = $t->timeout;
        $self->log_debug("temporarily forcing banner_timeout=$banner_timeout (from timeout=$save_timeout)");
        $t->timeout($banner_timeout);
    }

    my ($prematch, $match) = $t->waitfor(Match => $login_pattern);

    if (defined($banner_timeout)) {
        $self->log_debug("restoring timeout=$save_timeout");
        $t->timeout($save_timeout);
    }

    ($prematch, $match);
}

#
# Waits until the channel has been idle for $settle_ms milliseconds
# (nothing more arriving), WITHOUT consuming the stream: whatever is
# read to detect the idle is pushed back onto Net::Telnet's input
# buffer, so a following waitfor() still sees the settled prompt (and
# its prematch is intact). Used before matching a "settled" command
# prompt whose token is broad (allows spaces / Unicode and so could
# otherwise latch onto a banner line ending in the prompt sign): by
# waiting for output to stop first, the subsequent match sees the
# finished prompt as the last line rather than a transient mid-banner
# one. $settle_ms <= 0 disables the wait and does nothing.
#
sub drain_until_idle {
    my ($self, $t, $settle_ms) = @_;

    return unless defined($settle_ms) && $settle_ms > 0;

    my $buf = '';
    my $save_timeout = $t->timeout;
    my $save_errmode = $t->errmode;

    # Non-fatal, sub-second reads: each get() returns when a chunk
    # arrives or the short timeout elapses. One empty/timed-out read
    # after data means the channel has gone quiet.
    $t->errmode('return');

    my $idle = 0;
    while ($idle < 1) {
	my $chunk = $t->get(Timeout => $settle_ms / 1000.0);
	if (defined($chunk) && length($chunk)) {
	    $buf .= $chunk;
	    $idle = 0;
	}
	else {
	    $idle++;
	}
    }

    $t->timeout($save_timeout);
    $t->errmode($save_errmode);

    # Put back everything we consumed, at the front of the input
    # buffer, so the caller's waitfor() matches against the untouched
    # stream. buffer() returns a scalar ref to Net::Telnet's own input
    # buffer.
    if (length($buf)) {
	my $bref = $t->buffer;
	$$bref = $buf . $$bref;
    }

    return;
}

sub chat_show_conf {
    my ($self, $t, $show_cmd_default, $show_cmd_custom) = @_;

    my $cmd = defined($show_cmd_custom) ? $show_cmd_custom : $show_cmd_default;
    $self->log_debug("cmd: [".$cmd."]");

    my $ok = $t->print($cmd);
    if (!$ok) {
	$self->log_error("could not send show config command: $cmd");
	return 1;
    }

    undef;
}

#
# Implement model::Abstract - End
##################################

sub log_debug {
    my ($self, $msg) = @_;

    $self->{log}->debug($self->label . ": " . $msg);
}

sub log_error {
    my ($self, $msg) = @_;

    $self->{log}->error($self->label . ": " . $msg);
}

# remove heading and trailing blanks
#
# example: " a b c  " => "a b c"
#
sub opt_trim {
    my ($opt) = @_;
    if ($opt =~ /^\s*(\S|\S.*\S)\s*$/) {
	return $1;
    }
    $opt;
}

#
# Strips a genuinely-wrapping pair of double quotes from an already
# opt_trim()-ed option value (added by parse_options() below via
# Text::ParseWords with $keep=1 - that mode recognizes quotes for
# comma-splitting purposes and leaves a literal backslash in an
# UNQUOTED value untouched, but does not itself strip the quotes).
# A value that isn't quoted is returned unchanged, backslashes and
# all (e.g. a Windows "DOMAIN\user" style value). Only inside a
# genuinely-quoted value are \" and \\ unescaped to " and \, so a
# literal quote or backslash can be embedded in a quoted value, e.g.
# comment="Building 3, Floor 2" or comment="He said \"hi\"".
#
#
# Byte-safe alternative to quotemeta() for building a prompt regexp
# from a device-derived string. Two problems are handled:
#
#   1. quotemeta() backslash-escapes every byte that is not a word
#      character, so a multi-byte UTF-8 character (e.g. the two bytes
#      0xC3 0xBC of u-umlaut in a hostname) becomes "\<C3>\<BC>", which
#      then fails to match the same bytes on the wire. This escapes
#      ONLY the ASCII regex metacharacters and leaves every byte
#      >= 0x80 untouched.
#
#   2. The prompt string may carry Perl's UTF-8 flag (for example when
#      the device table came from a UTF-8-encoded file, as
#      fetchconfig-web's session .tbl does): a flagged string holds
#      u-umlaut as ONE character (U+00FC), so a pattern built from it
#      demands that character, while the pty delivers the raw bytes
#      0xC3 0xBC - and they do not match. utf8::encode() on a copy
#      turns the flagged text back into its raw UTF-8 bytes with the
#      flag cleared, so pattern and wire are both bytes. If the string
#      is already bytes (no flag) it is left unchanged. Only the
#      pattern is affected here; the stored config bytes are never
#      touched.
#
# Use this instead of quotemeta() when the quoted string may contain
# non-ASCII (see ArubaCXSSH.pm / PLANET.pm).
#
#
# Restricts a debug file to owner read/write (0600). Debug files
# (dump_log / the HTTP and SNMP debug traces) record the session
# verbatim, INCLUDING the login/enable password or the SNMP read-write
# community as sent, so they must never be world-readable regardless of
# the process umask. Accepts a filehandle or a path. Failure is logged
# but not fatal (the run continues); it is called on the file we just
# created, so the chmod applies to that exact file.
#
#
# Backup filename parsing - the ONE place that knows the format:
#
#     <dev_id>.run.YYYYMMDD.HHMMSS<tz><suffix>
#
# <tz> is whatever strftime produced when the file was written (see
# local_timestamp) and varies by platform and DST. Observed forms:
#   Linux / modern Windows (%z):  +0200  -0500          numeric offset
#   AIX (%Z, no separator):       CEST  CET  NFT  DFT   bare name,
#                                                       changes with DST
#   Solaris (our "-%Z" fallback): -BRST  -CEST          dash + name
#   Windows MSVCRT (%Z / old %z): W. Europe Standard Time
#                                 Mitteleuropäische Sommerzeit
#                                                       words with spaces,
#                                                       a dot, possibly
#                                                       non-ASCII letters
#   timezone=hide:                (empty)
#
# <suffix> is the filename_append_suffix. Since 9.55 it must start with
# "."; "-" and "_" are also accepted as separators so that backups
# written before that rule are still recognized. A suffix never contains
# whitespace (dump_config rejects it), while a Windows tz name always
# separates its words with whitespace - that is what lets the two be
# told apart. One inherent ambiguity: "-" followed by uppercase letters
# is the Solaris tz form, so an OLD suffix like "-BAK" on a
# timezone=hide file (no tz) is read as a tz; "_BAK", "-bak", or any
# suffix after a real tz token are unambiguous.
#
# Returns ($timestamp, $tz, $suffix) - timestamp "YYYYMMDD.HHMMSS", tz
# and suffix possibly '' - or an empty list if the name is not a backup
# of $dev_id in this format.
#
sub parse_backup_filename {
    my ($dev_id, $file) = @_;

    my $rest = $file;
    return () unless $rest =~ s/^\Q$dev_id\E\.run\.(\d{8}\.\d{6})//;
    my $ts = $1;

    my $tz = '';
    if ($rest =~ s/^([+-]\d{4})//) {
	$tz = $1;                                   # numeric offset
    }
    elsif ($rest =~ s/^(-?[A-Za-z\x80-\xff]+(?:\.?[ \t]+[A-Z\x80-\xff][A-Za-z\x80-\xff]*)*)//) {
	# name: bare (AIX) / dashed (Solaris) / Windows multi-word. Each
	# additional Windows word must start uppercase (or non-ASCII, for
	# localized names), so stray lowercase text after a tz is not
	# swallowed into it and gets flagged as malformed instead.
	$tz = $1;
    }

    my $suffix = '';
    if (length($rest)) {
	# a suffix must start with . - or _ and carry no whitespace
	return () unless $rest =~ /^[._-]\S*$/;
	$suffix = $rest;
    }

    ($ts, $tz, $suffix);
}

#
# Sorts backup filenames of $dev_id newest first by the PARSED
# timestamp, so neither the tz token (which changes with DST and by
# platform) nor a suffix can disturb the order; the full name is the
# tiebreaker. Names the parser cannot read are kept, ordered after the
# parsable ones by plain string comparison, and reported through the
# optional $unparsed_ref array so callers can log them.
#
sub sort_backups_desc {
    my ($dev_id, $files_ref, $unparsed_ref) = @_;

    my (@parsed, @unparsed);
    foreach my $f (@$files_ref) {
	my ($ts) = parse_backup_filename($dev_id, $f);
	if (defined($ts)) { push @parsed, [$ts, $f]; }
	else              { push @unparsed, $f; }
    }

    @$unparsed_ref = @unparsed if ref($unparsed_ref);

    ((map { $_->[1] } sort { $b->[0] cmp $a->[0] || $b->[1] cmp $a->[1] } @parsed),
     (sort { $b cmp $a } @unparsed));
}

sub secure_debug_file {
    my ($self, $target) = @_;

    # chmod accepts an open filehandle or a path.
    if (!chmod(0600, $target)) {
	$self->log_error("could not restrict permissions (0600) on debug file: $!");
	return 0;
    }

    1;
}

#
# Removes terminal control noise from device output: VT100/ANSI escape
# sequences, NUL bytes and carriage returns. Used by the models whose
# devices drive a full-screen or cursor-addressed terminal (ProCurve,
# ProCurveSSH) and by ComwareSSH for its "\r\r\n" line endings.
#
# Consolidated here in 9.58 from three per-model copies that had already
# diverged: the ProCurve copies had gained the DEC private-mode rule
# (ESC[?25l - the "25lswi11024" prompt bug) and the ESC E rule, while
# ComwareSSH's copy was frozen at the older two-rule form. Real captures
# used to verify this version: a ProCurve 2610 telnet session (the
# richest escape sample: cursor addressing, scroll regions, ?25h/?25l,
# ESC E), ProCurve SSH sessions (ESC[1H before the prompt), and an
# 80 KB Comware SSH session (no escapes at all, every line "\r\r\n", two
# NUL bytes at banner boundaries). Output is byte-identical to the old
# copies on all of them except where this version strips something
# they left behind (NULs; three-or-more-parameter CSI sequences).
#
#   ESC [ params letter   any CSI sequence - cursor moves, erase, SGR
#                         colours, scroll region - with ANY number of
#                         ";"-separated parameters and the "?" private
#                         forms (the old rule allowed at most two
#                         parameters, so "ESC[1;37;40m" survived it)
#   ESC E/M/D/7/8/=/>     two-byte escapes: NEL, RI, IND, cursor
#                         save/restore, keypad modes
#   NUL, CR               terminal padding and line-ending noise; never
#                         configuration content
#
# Plain function (not a method): call as
# fetchconfig::model::Abstract::stripansi($str), like
# regexp_quote_keep_bytes.
#
sub stripansi {
    my ($str) = @_;

    $str =~ s/\x1b\[[\d;?]*[A-Za-z]//g;
    $str =~ s/\x1b[EMD78=>]//g;
    $str =~ s/[\x00\x0d]//g;

    $str;
}

##################################
# SSH transport (9.59)
#
# Seven models drive a switch over SSH the same way: Net::OpenSSH makes
# the connection (password, no host-key verification), open2pty hands
# back a pseudo-terminal, and that pty is wrapped in Net::Telnet so the
# prompt handling written for the telnet models is reused. Each model
# used to carry its own 25-44 line copy of this; the copies had
# diverged in three ways, one of which was a gap: the three newest
# models wrote a complete .debug file (the ssh client's -v trace, then
# the session dump), ProCurveSSH wrote only the session dump, and
# CiscoIOSSSH/CiscoASASSH/ComwareSSH honoured debug=on for nothing at
# the SSH layer at all. The shared implementation below is the newest
# form, so every SSH model now gets the documented debug behaviour.
#
# What stays per model is the legacy-crypto knowledge: older switches
# need SHA1 key exchange, ssh-rsa host keys and CBC ciphers re-enabled.
# A model declares those with ssh_extra_opts(); the default is none.
#
# ssh_open() returns ($t, $ssh, $pid, $guard) on success or an empty
# list on failure (already logged). $ssh must be kept alive for the
# session (it is the master connection); $pid is the shell's pid for
# the final waitpid; $guard restores the previous __WARN__ handler when
# it goes out of scope, so keep it in a variable for the session too.
##################################

sub ssh_extra_opts { () }

#
# Net::OpenSSH allocates a pty (via IO::Pty) both for the password login
# and for open2pty. In the forked ssh child, IO::Pty calls setsid() to
# grab a controlling terminal; when the child is already a process-group
# leader that returns EPERM and IO::Pty prints "setsid() failed, strange
# behavior may result". Harmless here - the pty is still usable - so that
# cosmetic warning (and the related controlling-terminal ones) is
# filtered while every other warning passes. The handler is inherited by
# the forked child, so it must be in place before the SSH calls; it is
# restored when the returned guard is destroyed.
#
package fetchconfig::model::Abstract::WarnGuard;
sub new { my ($class, $prev) = @_; bless { prev => $prev }, $class }
sub DESTROY { $SIG{__WARN__} = $_[0]->{prev} }
package fetchconfig::model::Abstract;

sub ssh_open {
    my ($self, $dev_host, $dev_user, $dev_pass, $dev_timeout, $debug_fh) = @_;

    # Loaded on first use, not at compile time: Abstract.pm is shared by
    # every model, and a telnet-only installation need not have
    # Net::OpenSSH (see PERL MODULE REQUIREMENTS). Net::Telnet is a
    # hard requirement of every model and is loaded by the caller.
    if (!eval { require Net::OpenSSH; require IO::Handle; 1 }) {
	$self->log_error("Net::OpenSSH is required for SSH models but could not be loaded: $@");
	return;
    }

    my $prev_warn = $SIG{__WARN__};
    my $guard = fetchconfig::model::Abstract::WarnGuard->new($prev_warn);
    $SIG{__WARN__} = sub {
	my ($msg) = @_;
	return if $msg =~ /setsid\(\) failed|controlling termin/;
	if (ref($prev_warn) eq 'CODE') { $prev_warn->($msg) } else { warn $msg }
    };

    my $ssh = Net::OpenSSH->new($dev_host,
				user        => $dev_user,
				password    => $dev_pass,
				timeout     => $dev_timeout,
				# Deliberately no host-key verification: the
				# job runs unattended and a switch's host key
				# changes on every hardware swap. See SECURITY
				# NOTES in the README.
				master_opts => [-o => "StrictHostKeyChecking=no",
						-o => "UserKnownHostsFile=/dev/null",
						# DEBUG (= ssh -v, DEBUG1) gives the real trace:
						# kex algorithm, host key, auth methods tried,
						# "Authentication succeeded". VERBOSE, used before
						# 9.59, adds almost nothing above INFO and produced
						# no debug1: lines at all on AIX OpenSSH 8.1.
						-o => ($debug_fh ? "LogLevel=DEBUG" : "LogLevel=ERROR"),
						$self->ssh_extra_opts],
				($debug_fh ? (master_stderr_fh => $debug_fh) : ()));
    if ($ssh->error) {
	$self->log_error("could not connect: " . $ssh->error);
	print $debug_fh "# could not connect: " . $ssh->error . "\n" if $debug_fh;
	return;
    }

    print $debug_fh "# switch session (Net::Telnet dump_log)\n" if $debug_fh;

    $self->log_debug("connected");

    my ($pty, $pid) = $ssh->open2pty;
    if (!defined($pty)) {
	$self->log_error("unable to start remote shell: " . $ssh->error);
	return;
    }

    # Drive the SSH pty through Net::Telnet so the prompt handling of
    # the telnet models keeps working: telnetmode off (raw channel),
    # output record separator CR. Cmd_remove_mode only affects cmd(),
    # which none of the SSH models call.
    my @telnet_args = (Errmode                 => 'return',
		       Timeout                 => $dev_timeout,
		       Telnetmode              => 0,
		       Cmd_remove_mode         => 1,
		       Output_record_separator => "\r",
		       Fhopen                  => $pty);
    push @telnet_args, (dump_log => $debug_fh) if $debug_fh;

    my $t = Net::Telnet->new(@telnet_args);   # arrow form: Abstract.pm does not "use Net::Telnet" itself
    if (!defined($t)) {
	$self->log_error("could not attach to ssh pty");
	return;
    }

    ($t, $ssh, $pid, $guard);
}

#
# Opens <repository>/<dev_id>.debug (mode 0600) for an SSH model when
# debug=on, writes the header line, and returns the handle - or undef
# when debug is off or the file cannot be opened (logged). Shared by
# the SSH models so all of them produce the same debug file layout.
#
sub open_ssh_debug_file {
    my ($self, $dev_opt_tab, $dev_repository, $dev_id, $dev_host) = @_;

    return undef unless $self->dev_option_flag($dev_opt_tab, "debug", 0);

    my $debug_path = "$dev_repository/$dev_id.debug";
    my $debug_fh;
    if (open($debug_fh, '>', $debug_path)) {
	$self->secure_debug_file($debug_fh);   # contains credentials -> 0600
	$debug_fh->autoflush(1);
	print $debug_fh "# ssh master connection to $dev_host (LogLevel=DEBUG, i.e. ssh -v)\n";
	return $debug_fh;
    }

    $self->log_error("could not write debug file: $debug_path: $!");
    return undef;
}

sub regexp_quote_keep_bytes {
    my ($str) = @_;

    utf8::encode($str) if utf8::is_utf8($str);

    $str =~ s/([\\^\$.\[\]|()?*+{}\/#=!:<>~ -])/\\$1/g;

    $str;
}

sub dequote_value {
    my ($val) = @_;

    return $val unless $val =~ /^"(.*)"$/s;

    (my $inner = $1) =~ s/\\(["\\])/$1/g;

    $inner;
}

#
# Returns $line with any pass=... / enable=... value replaced by
# '***', so raw device_table lines can be logged (e.g. on a parse
# error) without leaking cleartext credentials.
#
sub mask_secrets {
    my ($line) = @_;

    (my $masked = $line) =~ s/\b(pass|enable|community)=[^,\s]*/$1=***/gi;

    $masked;
}

sub parse_options {
    my ($self, $label, $file, $line_num, $line, $opt_tab_ref, @options) = @_;

    foreach (@options) {
	#
	# Quote-aware split: a comma inside a double-quoted value
	# (e.g. comment="Building 3, Floor 2") is not treated as an
	# option separator. $keep=1 preserves the surrounding quotes
	# (stripped below by dequote_value) and - importantly - also
	# leaves a literal backslash in an UNQUOTED value untouched
	# (e.g. pass=DOMAIN\user); Text::ParseWords' default $keep=0
	# mode would silently eat it, corrupting such values. Quoting
	# is entirely optional, never required: an unquoted value
	# with no comma in it parses exactly as before.
	#
	foreach (Text::ParseWords::parse_line(',', 1, $_)) {
	    if (/^([^=]+)=(.*)$/) {
		my $opt = opt_trim($1);
		my $val = dequote_value(opt_trim($2));
		$opt_tab_ref->{$opt} = $val;
		next;
	    }
	    $self->log_error("bad $label option '" . mask_secrets($_) . "' at file=$file line=$line_num: " . mask_secrets($line));
	}
    }
}

sub dump_options {
    my ($self, $label, $opt_tab_ref) = @_;

    while (my ($name, $value) = each %$opt_tab_ref) {
	$self->log_debug("$label option: $name=$value");
    }
}

sub default_options {
    my ($self, $file, $line_num, $line, @model_default_options) = @_;

    $self->parse_options('default',
			 $file, $line_num, $line,
			 $self->{default_options},
			 @model_default_options);

    #$self->dump_options('default', $self->{default_options});
}

#
# Default fetch timeout (seconds) applied when neither the device line
# nor the model's default: line sets "timeout". Before 9.55 an unset
# timeout fell through to the underlying library's own default
# (Net::Telnet: 10 s; LWP::UserAgent: 180 s), which was both
# inconsistent across transports and undocumented.
#
my $DEFAULT_TIMEOUT_SEC = 30;

sub dev_option {
    my ($self, $dev_opt_tab, $opt_name) = @_;

    my $value = $dev_opt_tab->{$opt_name};

    return $value if defined($value);

    $value = $self->{default_options}->{$opt_name};

    return $value if defined($value);

    # "timeout" always has a value: fall back to the documented default
    # and say so, so a missing timeout in the device table is visible
    # in the debug output rather than silently becoming a library
    # default.
    if ($opt_name eq 'timeout') {
	$self->log_debug("Using ${DEFAULT_TIMEOUT_SEC}s fetch timeout because the timeout was not set for this model");
	return $DEFAULT_TIMEOUT_SEC;
    }

    undef;
}

#
# Reads an on/off device table option (e.g. "debug=on"). Returns 1
# when the option is set to "on" (case-insensitive), 0 for "off" or
# any other value, and $default (0/1) when the option is not
# specified at all.
#
sub dev_option_flag {
    my ($self, $dev_opt_tab, $opt_name, $default) = @_;

    my $value = $self->dev_option($dev_opt_tab, $opt_name);

    return $default ? 1 : 0 unless defined($value);

    (lc(opt_trim($value)) eq 'on') ? 1 : 0;
}

sub get_timestr {
    my $ts = time;
    my @local_ts_list = localtime($ts);
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = @local_ts_list;
    $year += 1900;
    ++$mon;
    my $tz_off = strftime '%z', @local_ts_list; 
    
    # The tz token that ends up in the backup filename is whatever the
    # platform's strftime gives, and it is NOT uniform:
    #   Linux / modern Windows: %z -> numeric offset, "+0200" / "-0500"
    #   AIX:   %z is not supported and yields the tz NAME directly, so
    #          the filename gets a bare "CEST" (summer) / "CET" (winter),
    #          or "NFT"/"DFT" on older AIX - i.e. it CHANGES WITH DST.
    #   Solaris: %z yields a literal "z", hence the "-%Z" fallback below,
    #          giving "-CEST" / "-BRST".
    #   older Windows (MSVCRT): a multi-word name such as
    #          "W. Europe Standard Time", possibly localized.
    # Consumers must therefore never assume one shape; see
    # parse_backup_filename, which recognizes all of these.
    if ($tz_off =~ /z/) {
        $tz_off = strftime '-%Z', @local_ts_list;
    }
    
    ($year, $mon, $mday, $hour, $min, $sec, $tz_off);
}

sub dump_config {
    my ($self, $dev_id, $dev_opt_tab, $conf_ref) = @_;

    #
    # A fetch that failed partway through (login error, "could not
    # find ...", etc.) can leave $conf_ref undefined; a fetch that
    # connected but somehow captured nothing leaves it as a
    # reference to an empty array. Either way there is no
    # configuration to save. Treat both the same as every other
    # do_fetch() failure path: log it and return undef, rather than
    # silently writing an empty file that would then be reported as
    # a successful, unchanged backup (and, for changes_only=1
    # devices, never get cleaned up since it "differs" from the real
    # previous backup).
    #
    if (!defined($conf_ref) || @$conf_ref < 1) {
	$self->log_error("no configuration retrieved - not saving an empty backup");
	return undef;
    }

    my $dev_repository = $self->dev_option($dev_opt_tab, "repository");

    my ($year, $mon, $day, $hour, $min, $sec, $tz_off) = get_timestr;

    my $dir_path = sprintf("$dev_repository/%04d%02d/%04d%02d%02d/$dev_id",
			   $year, $mon, $year, $mon, $day);

    if (! -d $dir_path) {
	my $mkdir_err;

	make_path($dir_path, { error => \$mkdir_err });

	if (@$mkdir_err) {
	    my $detail = join('; ', map {
		my ($failed_path, $mk_errmsg) = %$_;
		"$failed_path: $mk_errmsg";
	    } @$mkdir_err);

	    $self->log_error("could not create dir: $dir_path: $detail");
	    return undef;
	}
    }

    my $dev_timezone = $self->dev_option($dev_opt_tab, "timezone");
    if (defined($dev_timezone)) {
	if ($dev_timezone =~ /hide/i) {
		$tz_off = '';
	}
    }

    # NOTE: the filename has one-second resolution. Two backups of the
    # same device completed within the same second would get the same
    # name, so the second would overwrite the first and the changes_only
    # comparison would then compare the file with itself. This is an
    # accepted limitation: a real fetch (login, pager, full config,
    # logout) essentially never completes in under a second, and the
    # scheduled runs are minutes apart. It only shows up in artificial
    # back-to-back test runs. See README, "Backup file naming".
    my $file = sprintf("${dev_id}.run.%04d%02d%02d.%02d%02d%02d$tz_off",
		       $year, $mon, $day, $hour, $min, $sec);

    # filename_append_suffix: appended verbatim to the backup filename.
    # Since 9.55 it MUST start with a "." (e.g. ".txt"), so the suffix
    # reads as a file extension and cannot be confused with the
    # timezone token that precedes it in the name. A "/" would turn the
    # suffix into a path component and whitespace makes an unusable
    # name, so both are rejected too. An empty value means "no suffix".
    # A bad value fails THIS device's backup (nothing is written) with a
    # clear message rather than silently producing a misnamed file.
    my $dev_suffix = $self->dev_option($dev_opt_tab, "filename_append_suffix");
    if (defined($dev_suffix) && length($dev_suffix)) {
	if ($dev_suffix !~ /^\./) {
	    $self->log_error("dev=$dev_id: filename_append_suffix must start with a \".\" (got \"$dev_suffix\") - backup not written");
	    return undef;
	}
	if ($dev_suffix =~ m{[/\s]}) {
	    $self->log_error("dev=$dev_id: filename_append_suffix must not contain \"/\" or whitespace (got \"$dev_suffix\") - backup not written");
	    return undef;
	}
	$file .= $dev_suffix;
    }

    my $file_path = "$dir_path/$file";

    local *OUT;

    if (!open(OUT, '>', $file_path)) {
	$self->log_error("could not write dump file: $file_path: $!");
	return undef;
    }

    {
	# Terminate every line with "\n", INCLUDING the last one, so the
	# written file ends in a newline like the device's own output
	# (and like a POSIX text file). Using $, = "\n" would only put
	# newlines BETWEEN elements, leaving the file without a trailing
	# newline. See CHANGES 9.53: this affects every model's output.
	local $\ = '';
	local $, = '';
	print OUT map { "$_\n" } @$conf_ref;
    }

    if (!close(OUT)) {
	$self->log_error("could not close dump file: $file_path: $!");
	return undef;
    }

    ($dir_path, $file);
}

sub find_latest {
    my ($self, $dev_id, $dev_opt_tab) = @_;

    my $dev_repository = $self->dev_option($dev_opt_tab, "repository");

    my %dir_tab;

    if ($self->scan_dir(\%dir_tab, $dev_id, $dev_repository)) {
	$self->log_error("latest config not found - error scanning repository");
	return undef;
    }

    # Newest first by the PARSED timestamp, so the tz token (which
    # changes with DST and by platform) and any suffix cannot disturb
    # the order. See parse_backup_filename / sort_backups_desc.
    my @unparsed;
    my @files = sort_backups_desc($dev_id, [keys %dir_tab], \@unparsed);
    $self->log_error("dev=$dev_id: backup filename in unexpected format (ordered by name only): $_") for @unparsed;

    if (@files < 1) {
	$self->log_error("there is no latest config");
	return undef;
    }

    my $latest_file = $files[0];
    my $latest_dir = $dir_tab{$latest_file};

    ($latest_dir, $latest_file);
}

#
# Collects every backup file of $dev_id under $dir_path into
# %$dir_tab_ref (filename => directory). Returns 0 on success, 1 on
# error (already logged).
#
# The repository layout is <repo>/YYYYMM/YYYYMMDD/<dev_id>/files. A
# device's backups therefore live ONLY in directories literally named
# after it, so at the day level this opens "<day>/<dev_id>" directly
# instead of descending into every other device's directory. Before
# this, the whole tree was walked and every file of every device was
# stat()ed for each lookup: at 2,500 devices x 30 backups that was
# ~675 ms per device and ~28 minutes of pure directory walking per
# nightly run (find_latest is called once per device), and the same
# again for -Z/-S/-o; the pruned walk is ~0.2 ms per device. Results
# are identical (verified against a 150k-inode synthetic repository).
#
# Anything that is not a well-formed month/day directory is still
# walked the old way (files at odd depths keep being found), so the
# safety net for non-standard layouts is unchanged; only the known
# layout is pruned.
#
sub scan_dir {
    my ($self, $dir_tab_ref, $dev_id, $dir_path) = @_;

    my $error = 0;

    local *DIR;

    if (!opendir(DIR, $dir_path)) {
	# A directory that disappeared between being listed by our caller
	# and being opened here (or a repository that does not exist yet
	# on a device's first run) simply contributes no backups. With
	# parallel fetching (-P) concurrent workers and the parent create,
	# rename and remove entries in the shared date directories and
	# the repository root all the time, so this is a normal race, not
	# a fault. Anything other than "does not exist" is still an error.
	return 0 if $!{ENOENT};
	$self->log_error("could not open dir: $dir_path: $!");
	return 1;
    }

    my $pattern = quotemeta($dev_id) . '\.run\.';

    foreach (readdir DIR) {
	my $file = "$dir_path/$_";

	if (-f $file) {
	    next unless ($_ =~ /^$pattern/);
	
	    if (exists($dir_tab_ref->{$_})) {
		$self->log_error("ugh: duplicate backup file: $_");
		return 1;
	    }
	    $dir_tab_ref->{$_} = $dir_path;
	
	    next;
        }

        next if (/^\./);

	# Neither a regular file nor a directory: the entry vanished
	# between readdir and stat (e.g. the parent's atomic rename of a
	# .status temp file while a -P worker scans), or it is a socket,
	# broken symlink, etc. Nothing to descend into - skip it. Before
	# this it was treated as a directory, the opendir failed, and a
	# harmless race became "latest config not found", which made
	# changes_only save an unchanged config.
	next unless -d $file;

	# Known layout: a day directory (YYYYMMDD). Only the device's own
	# subdirectory can hold its backups - open just that one, and
	# skip the day entirely if it is absent (ENOENT is the cheap,
	# common case: the device has no backup on that day).
	if (/^\d{8}$/ && -d $file) {
	    my $dev_dir = "$file/$dev_id";
	    next unless -d $dev_dir;
	    if ($self->scan_dir($dir_tab_ref, $dev_id, $dev_dir)) {
		$error = 1;
		last;
	    }
	    next;
	}

	# Month directory (YYYYMM) or anything unexpected: recurse as
	# before. The month level is small (one entry per month), and the
	# fallback keeps oddly placed files discoverable.
	if ($self->scan_dir($dir_tab_ref, $dev_id, $file)) {
	    $error = 1;
	    last;
	}
    }

    if (!closedir(DIR)) {
	$self->log_error("could not close dir: $dir_path: $!");
	return 1;
    }

    $error;
}

sub config_equal {
    my ($self, $prev_dir, $prev_file, $curr_dir, $curr_file) = @_;

    my $prev_path = "$prev_dir/$prev_file";
    my $curr_path = "$curr_dir/$curr_file";

    my $result = compare($prev_path, $curr_path);
    if ($result < 0) {
	$self->log_error("failure comparing $prev_path to $curr_path");
    }

    # -1: error: return false, in order to keep the newer version
    # 0: equal: return true, in order to allow discarding the newer version
    # 1: distinct: return false, in order to keep the newer version

    !$result;
}

#
# Same purpose as config_equal(), for models whose config always
# embeds a volatile line that must not by itself count as a change
# (e.g. Cisco ASA's "!!: Written by admin at HH:MM:SS.mmm TZ Day Mon
# DD YYYY" save-timestamp banner, rewritten on every "show run" even
# when nothing else changed). Any line matching $ignore_re is
# stripped from both files before comparing.
#
sub config_equal_ignoring_lines {
    my ($self, $prev_dir, $prev_file, $curr_dir, $curr_file, $ignore_re) = @_;

    my $prev_path = "$prev_dir/$prev_file";
    my $curr_path = "$curr_dir/$curr_file";

    my $prev_text = $self->read_lines_ignoring($prev_path, $ignore_re);
    my $curr_text = $self->read_lines_ignoring($curr_path, $ignore_re);

    # error reading either file: return false, in order to keep the newer version
    return 0 unless (defined($prev_text) && defined($curr_text));

    ($prev_text eq $curr_text);
}

#
# Returns the content of $path as a single string, with any line
# matching $ignore_re removed, or undef on error (already logged).
#
sub read_lines_ignoring {
    my ($self, $path, $ignore_re) = @_;

    local *IN;

    if (!open(IN, '<', $path)) {
	$self->log_error("could not read for comparison: $path: $!");
	return undef;
    }

    my @lines = grep { !/$ignore_re/ } <IN>;

    if (!close(IN)) {
	$self->log_error("could not close after comparison: $path: $!");
	return undef;
    }

    join('', @lines);
}

sub prune_dir_tree {
    my ($self, $depth, $dir) = @_;

    #$self->log_debug("prunning depth=$depth: $dir");

    return if ($depth < 1);

    if (rmdir $dir) {
	my @labels = split /\//, $dir;

	pop @labels;

	my $parent = join '/', @labels;

	$self->prune_dir_tree($depth - 1, $parent);
	
	return;
    }

    #$self->log_debug("could not rmdir: $dir: $!");
}

sub config_discard {
    my ($self, $config_dir, $config_file) = @_;

    my $path = "$config_dir/$config_file";

    #$self->log_debug("discarding: $path");

    if (unlink($path) != 1) {
	$self->log_error("could not discard config file: $path; $!");
	return;
    }

    $self->prune_dir_tree(3, $config_dir);
}

sub purge_ancient {
    my ($self, $dev_id, $dev_opt_tab) = @_;

    my $dev_keep = $self->dev_option($dev_opt_tab, "keep");
    if (!defined($dev_keep)) {
	$self->log_error("dev=$dev_id: unspecified maximum of config files to keep");
	return;
    }

    my $dev_repository = $self->dev_option($dev_opt_tab, "repository");

    my %dir_tab;

    if ($self->scan_dir(\%dir_tab, $dev_id, $dev_repository)) {
	$self->log_error("dev=$dev_id: could not load full device config list - error scanning repository");
	return;
    }

    my @files = keys %dir_tab;

    my $expired = @files - $dev_keep;

    $self->log_debug("dev=$dev_id: expire: existing=". scalar @files . " keep=$dev_keep should_expire=$expired");

    return if ($expired < 1);

    my @sorted = sort @files;

    for (my $i = 0; $i < $expired; ++$i) {
	my $file = $sorted[$i];
	my $dir = $dir_tab{$file};

	$self->log_debug("dev=$dev_id: expiring: $dir/$file");

	$self->config_discard($dir, $file);
    }
}

sub escape_brackets {
    my ($str) = @_;

    $str =~ s/\@/\\\@/g;
    $str =~ s/\[/\\\[/g;
    $str =~ s/\]/\\\]/g;

    $str;
}

#
# Shared "wait for the enable prompt" (9.58). Before this, 26 models each
# carried a private copy of the same 12-line function whose ONLY difference
# was the regex tail after the hostname - "#$", "# ?$", " > $",
# "> \(enable\) $", ... - one line of device knowledge wrapped in a dozen
# lines of scaffolding. The scaffolding lives here now; a model contributes
# its device fact by overriding prompt_tail() (and prompt_head() for
# prompts that wrap the hostname, e.g. Hirschmann "(host) #" or Comware
# "[host-view]"). The defaults reproduce the classic "hostname#" case, so
# a model with that prompt needs no override at all.
#
# The prompt is quoted byte-safely (regexp_quote_keep_bytes), so a "." in
# the hostname is literal and a non-ASCII byte is matched as-is. 21 of the
# old copies interpolated the prompt raw into the regex ("." meant "any
# character"); models are moved onto this implementation one at a time,
# each verified against its captured prompt lines.
#
# $tail_override, if given, replaces prompt_tail() for this one call - for
# the few models whose prompt sign varies per command (Acme). $label, if
# given, prefixes the error message (Parks/Riverstone name their steps).
#
# A model that still defines its own expect_enable_prompt keeps using it
# (normal method resolution); deleting that copy switches it to this one.
#
sub prompt_head { '' }
sub prompt_tail { '#$' }

sub expect_enable_prompt {
    my ($self, $t, $prompt, $tail_override, $label) = @_;

    if (!defined($prompt)) {
	$self->log_error("internal failure: undefined command prompt");
	return undef;
    }

    my $tail = defined($tail_override) ? $tail_override : $self->prompt_tail;

    my $enable_prompt_regexp = '/' . $self->prompt_head
			     . regexp_quote_keep_bytes($prompt)
			     . $tail . '/';

    my ($prematch, $match) = $t->waitfor(Match => $enable_prompt_regexp);
    if (!defined($prematch)) {
	# $label (optional, e.g. "fetching-config") names the step in the
	# error message, as the Parks/Riverstone copies did.
	$self->log_error((defined($label) ? "$label: " : "") . "could not match enable command prompt: $enable_prompt_regexp");
    }

    ($prematch, $match);
}

sub expect_enable_prompt_paging_auto {
    my ($self, $t, $prompt, $paging_prompt) = @_;

    if (!defined($prompt)) {
        $self->log_error("internal failure: undefined command prompt");
        return undef;
    }

    my $escaped_prompt = &escape_brackets($prompt);
    #$self->log_debug("regexp='$prompt' escaped_brackets='$escaped_prompt'");
    my $prompt_regexp = '/(' . $escaped_prompt . '#$)|(\Q' . $paging_prompt . '\E$)/';

    my ($prematch, $match, $full_prematch);

    for (;;) {
        $self->log_debug("paging: searching: $prompt_regexp");
        ($prematch, $match) = $t->waitfor(Match => $prompt_regexp);
        if (!defined($prematch)) {
            $self->log_error("could not match enable/paging prompt: $prompt_regexp");
            return; # signals error with undef
        }

        $self->log_debug("paging: found: match=[$match]");

        $full_prematch .= $prematch;

        if ($match ne $paging_prompt) {
            $self->log_debug("paging: done: match=[$match] paging_prompt=[$paging_prompt]");
            last;
        }

        # Do paging
        my $ok = $t->put(' '); # SPACE
        if (!$ok) {
            $self->log_error("could not send paging SPACE command");
            return; # signals error with undef
        }
    }

    ($full_prematch, $match);
}

1;

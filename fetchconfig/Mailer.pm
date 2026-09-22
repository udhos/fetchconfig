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
# $Id: Mailer.pm,v 9.27 2026/08/31 12:00:00 tammer Exp $

package fetchconfig::Mailer; # fetchconfig/Mailer.pm

#
# Collects per-device backup results over the course of a run and, at
# the end of it, e-mails a summary: a small statistics table (State:
# success/failed counts; Changes: changed/unchanged/n-a counts)
# followed by the full per-device table ("Device-ID", "Date", "Time",
# "State", "Size", "Changes"):
#
#   - the globally configured recipient (email: to=...) always gets a
#     summary of every device processed in the run;
#   - a device whose recipient was overridden (device-specific option
#     "to=...") is left out of nobody's mail except its own: it is
#     bundled with every other device sharing that same override
#     recipient into a separate mail, sent only to that recipient.
#
# Both tables use the same simple color scheme (inline styles, since
# many mail clients strip <style> blocks): a solid header row, body
# rows alternating between two shades of grey, "failed" always shown
# in red, and "changed" always shown in blue, wherever either word
# appears (State/Changes columns of the device table, and the
# matching rows of the statistics table). The whole e-mail uses
# sans-serif (the browser/OS default, since named fonts like Calibri
# aren't reliably installed across recipients), and ends with a small
# copyright/version footer line.
#
# Entirely opt-in: unless a device_table/-line= "email:" entry is
# present, record_result() calls are cheap (just an array push) and
# send_summaries() does nothing at all -- no SMTP connection is ever
# attempted.
#

use strict;
use warnings;
use Net::SMTP;
use MIME::Base64 qw(encode_base64);
use POSIX qw(strftime);
use Text::ParseWords ();
use fetchconfig::Constants;

my $log;

my $email_seen = 0; # true once at least one "email:" line has been parsed
my %email_config;   # from=, to=, smtp=, user=, password=

my @results; # list of { dev_id, dev_host, ts, success, size, changed, to }

my $FONT_FAMILY = 'sans-serif';

my $HEADER_BG = '#22aabb';
my @ROW_BG    = ('#cfcfcf', '#afafaf');
my $FAILED_FG  = '#ff0000';
my $CHANGED_FG = '#0000ff';

#
# remove heading and trailing blanks (same rule as
# model::Abstract::opt_trim; duplicated here to keep this module
# self-contained, same as e.g. mask_secrets is duplicated between
# Detector.pm and model::Abstract.pm)
#
sub trim {
    my ($str) = @_;
    if ($str =~ /^\s*(\S|\S.*\S)\s*$/) {
	return $1;
    }
    $str;
}

#
# Strips surrounding double quotes from an option value (duplicated
# from model::Abstract::dequote_value to keep this module
# self-contained). A matched pair "..." is unwrapped and \" / \\
# escapes inside it are unescaped; a single stray leading or trailing
# quote (an unbalanced value that Text::ParseWords leaves as-is) is
# also removed, so a mistyped footer="(c) ... doesn't render its
# quote literally in the mail.
#
sub dequote_value {
    my ($val) = @_;

    if ($val =~ /^"(.*)"$/s) {
	(my $inner = $1) =~ s/\\(["\\])/$1/g;
	return $inner;
    }

    $val =~ s/^"//;
    $val =~ s/"$//;

    $val;
}

#
# Returns $line with any password=... value replaced by '***', so a
# raw "email:" line can be logged (e.g. on a parse error) without
# leaking the SMTP credential.
#
sub mask_password {
    my ($line) = @_;

    (my $masked = $line) =~ s/\bpassword=[^,\s]*/password=***/gi;

    $masked;
}

sub escape_html {
    my ($str) = @_;

    return '' unless defined($str);

    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;

    $str;
}

#
# Wraps the literal text "failed" in red/bold; anything else is
# returned unchanged. Applied to both tables, wherever "failed" shows
# up (State column, and the failed-count row of the statistics
# table).
#
sub red_if_failed {
    my ($text) = @_;

    return $text unless defined($text) && $text eq 'failed';

    "<span style=\"color: $FAILED_FG; font-weight: bold;\">failed</span>";
}

#
# Wraps the literal text "changed" in blue; anything else (including
# "unchanged", which contains "changed" as a substring but must not
# match here) is returned unchanged.
#
sub blue_if_changed {
    my ($text) = @_;

    return $text unless defined($text) && $text eq 'changed';

    "<span style=\"color: $CHANGED_FG; font-weight: bold;\">changed</span>";
}

sub header_row_html {
    my (@cols) = @_;

    my $html = '<tr>';
    foreach my $col (@cols) {
	$html .= '<th style="background-color: ' . $HEADER_BG . '; color: #ffffff; '
	    . 'padding: 4px 8px; border: 1px solid #888888; text-align: left; '
	    . 'font-family: ' . $FONT_FAMILY . '; '
	    . 'line-height: 100%; mso-line-height-rule: exactly;">'
	    . escape_html($col) . '</th>';
    }
    $html .= "</tr>\n";

    $html;
}

#
# @cell_html is pre-formatted cell content (already escaped/colored
# by the caller) - not re-escaped here.
#
sub body_row_html {
    my ($row_index, @cell_html) = @_;

    my $bg = $ROW_BG[$row_index % 2];

    my $html = '<tr style="background-color: ' . $bg . ';">';
    foreach my $cell (@cell_html) {
	$html .= '<td style="padding: 4px 8px; border: 1px solid #888888; font-family: ' . $FONT_FAMILY
	    . '; line-height: 100%; mso-line-height-rule: exactly;">' . $cell . '</td>';
    }
    $html .= "</tr>\n";

    $html;
}

sub init {
    my ($class, $logger) = @_;

    $log = $logger;
}

#
# Parses an "email:" device_table line, e.g.:
#   email: from=config.backup@acme.com,to=admin@acme.com,smtp=FQDN,user=xxx,password=xxx
# "user"/"password" are optional. "footer" is optional too: it sets the
# copyright text in the summary mail's footer (the " - Version <n>" that
# follows it is fixed); it must not contain a comma. May be given more
# than once; later
# values overwrite earlier ones for the same key (same merge rule
# used by "default:").
#
sub parse_email_line {
    my ($class, $file, $line_num, $line, $rest) = @_;

    $email_seen = 1;

    # Quote-aware split, like the device options in model::Abstract:
    # a comma inside a double-quoted value (e.g. a footer that reads
    # "(c) 2026 ACME, Inc.") is not an option separator, and the
    # surrounding quotes are stripped from the value. $keep=1 leaves a
    # literal backslash in an unquoted value untouched. Quoting stays
    # optional; an unquoted, comma-free value parses exactly as before.
    foreach (Text::ParseWords::parse_line(',', 1, $rest)) {
	next unless defined && /\S/;
	if (/^([^=]+)=(.*)$/s) {
	    my $opt = trim($1);
	    my $val = dequote_value(trim($2));
	    $email_config{$opt} = $val;
	    next;
	}
	$log->error("bad email option '" . mask_password($_) . "' at file=$file line=$line_num: " . mask_password($line));
    }
}

#
# Records the outcome of one device's fetch attempt, to be folded
# into the end-of-run summary e-mail(s). $args{to}, if defined, is
# the device's overridden recipient (device-specific "to=" option).
#
# Also writes the per-device status file <repository>/<dev_id>.status
# (see write_status_file), unconditionally - it is a repository
# artifact, not part of the e-mail feature, so it is produced even
# when no "email:" line is configured.
#
# Parallel fetching (fetchconfig.pl -P): a worker process cannot share
# @results with the parent. While a result sink is set
# (set_result_sink), the row is serialized to that file instead of
# being kept; the parent later calls replay_result_file, which feeds
# each row through this same routine - so @results, the .status file
# and send_summaries all happen in the parent, exactly as at -P 1.
#
my $result_sink;   # path, or undef

sub set_result_sink {
    my ($class, $path) = @_;
    $result_sink = $path;
}

sub record_result {
    my ($class, %args) = @_;

    if (defined($result_sink)) {
	# One row per line: key=value pairs, tab-separated. Values are
	# escaped so tabs/newlines/backslashes survive; undef is kept
	# distinct from '' (as "~") so the replay reproduces it exactly.
	if (open(my $fh, '>>', $result_sink)) {
	    my @kv;
	    foreach my $k (sort keys %args) {
		my $v = $args{$k};
		if (!defined($v)) { push @kv, "$k=~"; next; }
		$v =~ s/\\/\\\\/g; $v =~ s/\t/\\t/g; $v =~ s/\n/\\n/g;
		push @kv, "$k=$v";
	    }
	    print $fh join("\t", @kv), "\n";
	    close $fh;
	}
	else {
	    $log->error("cannot write result sink $result_sink: $!");
	}
	return;
    }

    push @results, { %args };

    $class->write_status_file(\%args);
}

sub replay_result_file {
    my ($class, $path) = @_;

    return unless -f $path;
    open(my $fh, '<', $path) or do { $log->error("cannot read result file $path: $!"); return; };
    while (my $line = <$fh>) {
	chomp $line;
	next unless length $line;
	my %args;
	foreach my $kv (split /\t/, $line) {
	    my ($k, $v) = split /=/, $kv, 2;
	    next unless defined $k;
	    if (defined($v) && $v eq '~') { $args{$k} = undef; next; }
	    $v = '' unless defined $v;
	    $v =~ s/\\n/\n/g; $v =~ s/\\t/\t/g; $v =~ s/\\\\/\\/g;
	    $args{$k} = $v;
	}
	$class->record_result(%args);
    }
    close $fh;
}

#
# Writes <repository>/<dev_id>.status as an INI-style file: a
# [<dev_id>] section header, then key=value lines. Consumed by
# external tools (e.g. fetchconfig-web uses backup_duration_sec for
# its progress spinner). Overwritten on every run. Never fatal: a
# problem here is logged and the run continues.
#
# Fields (from the arguments record_result already receives, plus
# elapsed/dev_opt_tab/changes_only added at the call sites):
#   backup_start_date/time  derived from the end timestamp minus the
#                           duration (epoch subtraction, so leap years,
#                           month lengths and DST are handled by the
#                           time library, not by hand)
#   backup_end_date/time    the end timestamp
#   backup_duration_sec     integer seconds
#   backup_state            success | failed | skipped
#   backup_changed          unchanged | changed | forced | unknown
#
sub write_status_file {
    my ($class, $args) = @_;

    my $dev_id       = $args->{dev_id};

    return unless defined($dev_id);

    # The repository is resolved at the call site (via the model's
    # dev_option, which also consults the default: options) and passed
    # in explicitly; it is where every other per-device artifact lives.
    my $repository = $args->{repository};
    if (!defined($repository) || !length($repository)) {
	$log->error("cannot write status file for $dev_id: no repository");
	return;
    }

    # $args->{ts} is the fetch START time; duration is elapsed seconds.
    # End = start + duration. (Start is a real recorded timestamp here,
    # so no derivation is needed; the subtraction path is kept for the
    # documented contract in case a caller ever passes only the end.)
    my $duration = $args->{elapsed};
    $duration = 0 unless defined($duration) && $duration =~ /^\d+$/;

    my $start_ts = $args->{ts};
    my $end_ts;
    if (defined($start_ts)) {
	$end_ts = $start_ts + $duration;
    }
    else {
	# Only an end time known: derive start by epoch subtraction.
	$end_ts   = time;
	$start_ts = $end_ts - $duration;
    }

    my $state;
    if (defined($args->{state})) {
	$state = $args->{state};                 # explicit, if a caller sets it
    }
    elsif (!defined($args->{success})) {
	$state = 'skipped';
    }
    else {
	$state = $args->{success} ? 'success' : 'failed';
    }

    my $changed;
    if ($state ne 'success') {
	$changed = 'unknown';                    # no meaningful comparison
    }
    elsif ($args->{changes_only}) {
	$changed = ($args->{changed} && $args->{changed} eq 'unchanged')
		 ? 'unchanged' : 'changed';
    }
    else {
	$changed = 'forced';                     # changes_only=0: saved regardless
    }

    my $path = "$repository/$dev_id.status";
    # The temp file is a DOTFILE (".<dev_id>.status.tmp.<pid>") so that
    # a concurrent -P worker scanning the repository root skips it by
    # name (scan_dir ignores entries starting with "."). Without the
    # dot, a worker could list it, then find it gone after the rename
    # below - the race that produced "could not open dir ... .status.tmp"
    # errors in a parallel run.
    my $tmp  = "$repository/.$dev_id.status.tmp.$$";

    if (!open(my $fh, '>', $tmp)) {
	$log->error("cannot write status file $path: $!");
	return;
    }
    else {
	# Localize the output separators: Abstract::dump_config sets a
	# global $, = "\n" that is not restored, so a bare multi-arg
	# print here would otherwise get newlines inserted between
	# every argument. Build one string and print it as a single
	# argument, with $, and $\ neutralized for safety.
	local $, = '';
	local $\ = '';
	my $body =
	      "[$dev_id]\n"
	    . "backup_start_date=" . iso_date($start_ts) . "\n"
	    . "backup_start_time=" . iso_time($start_ts) . "\n"
	    . "backup_end_date="   . iso_date($end_ts)   . "\n"
	    . "backup_end_time="   . iso_time($end_ts)   . "\n"
	    . "backup_duration_sec=$duration\n"
	    . "backup_state=$state\n"
	    . "backup_changed=$changed\n";
	print $fh $body;
	close($fh);
    }

    # Atomic replace so a reader (the web spinner) never sees a
    # half-written file.
    if (!rename($tmp, $path)) {
	$log->error("cannot rename status file into place $path: $!");
	unlink($tmp);
    }
}

sub iso_date {
    my ($ts) = @_;

    strftime('%Y-%m-%d', localtime($ts));
}

sub iso_time {
    my ($ts) = @_;

    strftime('%H:%M:%S', localtime($ts));
}

#
# Small "State"/"Changes" counts table, meant to sit above the
# per-device table in the same e-mail, reflecting only the rows in
# $rows_ref (i.e. per-recipient, not global).
#
sub build_stats_table_html {
    my ($class, $rows_ref) = @_;

    my %state_count;
    my %changed_count;

    foreach my $row (@$rows_ref) {
	$state_count{$row->{success} ? 'success' : 'failed'}++;
	$changed_count{defined($row->{changed}) ? $row->{changed} : 'n/a'}++;
    }

    my $html = "<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse: collapse;\">\n";
    $html .= header_row_html('Statistic', 'Count');

    my $row_index = 0;

    foreach my $key ('success', 'failed') {
	$html .= body_row_html($row_index++, red_if_failed($key), $state_count{$key} || 0);
    }

    foreach my $key ('changed', 'unchanged', 'n/a') {
	next if ($key eq 'n/a' && !$changed_count{$key}); # only show n/a if it actually occurred
	$html .= body_row_html($row_index++, blue_if_changed(escape_html($key)), $changed_count{$key} || 0);
    }

    $html .= "</table>\n";

    $html;
}

sub build_device_table_html {
    my ($class, $rows_ref) = @_;

    my $html = "<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse: collapse;\">\n";
    $html .= header_row_html('Device-ID', 'Date', 'Time', 'State', 'Size', 'Changes');

    my $row_index = 0;

    foreach my $row (@$rows_ref) {
	my $state = $row->{success} ? 'success' : 'failed';
	my $size  = defined($row->{size}) ? $row->{size} : '-';

	$html .= body_row_html($row_index++,
				escape_html($row->{dev_id}),
				iso_date($row->{ts}),
				iso_time($row->{ts}),
				red_if_failed($state),
				escape_html($size),
				blue_if_changed($row->{changed}));
    }

    $html .= "</table>\n";

    $html;
}

#
# Full e-mail body: heading, statistics table, then the per-device
# table, all for the same set of rows.
#
sub build_report_html {
    my ($class, $rows_ref, $heading) = @_;

    my $html = '<html><body style="font-family: ' . $FONT_FAMILY . ';">' . "\n";

    $html .= '<p style="font-family: ' . $FONT_FAMILY . ';">' . escape_html($heading) . "</p>\n" if defined($heading);

    $html .= $class->build_stats_table_html($rows_ref);

    # A CSS margin on <table> isn't reliably honored by Outlook's
    # Word-based rendering engine, so the gap between the two tables
    # is an explicit spacer block instead.
    $html .= '<div style="height: 16px; line-height: 16px; font-size: 1px;">&nbsp;</div>' . "\n";

    $html .= $class->build_device_table_html($rows_ref);

    # Footer copyright text is configurable via "email: footer=..."; the
    # " - Version <n>" that follows is fixed. Default names the project's
    # authors. (Note: email-line options are comma-split, so a footer
    # value must not contain a comma.)
    my $footer = $email_config{footer};
    $footer = '(c) 2006-2026 Everton da Silva Marques, Rainer Tammer and others'
	unless defined($footer);

    $html .= '<p style="font-family: ' . $FONT_FAMILY . '; font-size: 10px; color: #888888; margin-top: 16px;">'
	. escape_html($footer) . ' - Version ' . escape_html(fetchconfig::Constants::version())
	. "</p>\n";

    $html .= "</body></html>\n";

    $html;
}

#
# Sends one e-mail: $to_line may hold one or more ';'-separated
# addresses. Every failure is logged and non-fatal to the caller (a
# mail problem must never abort the backup run itself).
#
sub send_mail {
    my ($class, $to_line, $subject, $html_body) = @_;

    my $host = $email_config{smtp};

    # A port given as part of the host ("smtp=mail.acme.com:587") is
    # honoured, but an explicit "port=" option wins; the default is
    # chosen below once the TLS mode is known (25 for off/starttls,
    # 465 for ssl).
    my $port_from_host;
    if ($host =~ /^([^:]+):(\d+)$/) {
	$host = $1;
	$port_from_host = $2;
    }

    my @rcpt_list = grep { length($_) } map { trim($_) } split /;/, $to_line;

    if (@rcpt_list < 1) {
	$log->error("fetchconfig::Mailer: no valid recipient in '" . mask_password($to_line) . "' - skipping mail");
	return;
    }

    # TLS: "email: tls=off|starttls|ssl" (default off = plain SMTP, the
    # historical behaviour). "ssl" opens a TLS connection from the start
    # (typically port 465); "starttls" connects in clear and upgrades
    # with STARTTLS (typically 25/587). Both need IO::Socket::SSL (which
    # needs Net::SSLeay); plain SMTP needs neither. If TLS is requested
    # but the module is missing, or the upgrade fails, the mail is NOT
    # sent - we never fall back to plaintext, since that would silently
    # defeat the point of enabling TLS.
    my $tls = lc(defined($email_config{tls}) ? $email_config{tls} : 'off');
    if ($tls !~ /^(off|starttls|ssl)$/) {
	$log->error("fetchconfig::Mailer: bad tls option '$tls' (use off, starttls or ssl) - skipping mail");
	return;
    }

    # Port: "email: port=N" (explicit) > "smtp=host:N" > TLS-aware default.
    # Works with every tls setting; the default just follows the
    # convention for each mode (25 plain / STARTTLS, 465 implicit TLS),
    # so "tls=ssl" works without also typing port=465.
    my $port = $email_config{port};
    $port = $port_from_host unless defined($port) && length($port);
    if (!defined($port) || !length($port)) {
	$port = ($tls eq 'ssl') ? 465 : 25;
    }
    if ($port !~ /^\d+$/ || $port < 1 || $port > 65535) {
	$log->error("fetchconfig::Mailer: bad port '$port' (must be 1-65535) - skipping mail");
	return;
    }

    my $want_tls = ($tls ne 'off');
    if ($want_tls) {
	if (!eval { require IO::Socket::SSL; 1 }) {
	    $log->error("fetchconfig::Mailer: tls=$tls requested but IO::Socket::SSL is not installed - skipping mail (not falling back to plaintext)");
	    return;
	}
    }

    my $smtp = Net::SMTP->new($host,
			      Port    => $port,
			      Timeout => 30,
			      Hello   => 'fetchconfig',
			      ($tls eq 'ssl' ? (SSL => 1) : ()));

    if (!defined($smtp)) {
	$log->error("fetchconfig::Mailer: could not connect to SMTP server $host:$port" . ($tls eq 'ssl' ? ' (SSL)' : '') . ": $!");
	return;
    }

    if ($tls eq 'starttls') {
	if (!$smtp->starttls()) {
	    $log->error("fetchconfig::Mailer: STARTTLS to $host:$port failed - skipping mail (not falling back to plaintext): " . ($smtp->message || $IO::Socket::SSL::SSL_ERROR || ''));
	    $smtp->quit;
	    return;
	}
    }

    my $user     = $email_config{user};
    my $password = $email_config{password};

    if (defined($user) && length($user)) {
	$smtp->command('AUTH', 'LOGIN');
	$smtp->response();
	if ($smtp->code != 334) {
	    $log->error("fetchconfig::Mailer: SMTP server $host:$port did not accept AUTH LOGIN (code=" . $smtp->code . ")");
	    $smtp->quit;
	    return;
	}

	$smtp->command(encode_base64($user, ''));
	$smtp->response();

	$smtp->command(encode_base64(defined($password) ? $password : '', ''));
	$smtp->response();

	if ($smtp->code != 235) {
	    $log->error("fetchconfig::Mailer: SMTP authentication to $host:$port failed (code=" . $smtp->code . ")");
	    $smtp->quit;
	    return;
	}
    }

    my $from = $email_config{from};

    # Header injection guard: a value carrying "\r" or "\n" (the device
    # table is operator-controlled, but fetchconfig-web writes it from
    # user input) could otherwise smuggle extra headers into the message.
    # Strip line breaks from every field that goes into a header. The
    # recipients also go into the SMTP envelope, so clean them too.
    my $hdr_clean = sub { my ($v) = @_; $v = '' unless defined($v); $v =~ s/[\r\n]+/ /g; $v };
    $from      = $hdr_clean->($from);
    $subject   = $hdr_clean->($subject);
    @rcpt_list = map { $hdr_clean->($_) } @rcpt_list;

    if (!$smtp->mail($from)) {
	$log->error("fetchconfig::Mailer: SMTP server $host:$port rejected MAIL FROM=<$from>");
	$smtp->quit;
	return;
    }

    if (!$smtp->to(@rcpt_list)) {
	$log->error("fetchconfig::Mailer: SMTP server $host:$port rejected RCPT TO=<" . join('>,<', @rcpt_list) . ">");
	$smtp->quit;
	return;
    }

    $smtp->data;
    $smtp->datasend("From: $from\n");
    $smtp->datasend("To: " . join(', ', @rcpt_list) . "\n");
    $smtp->datasend("Subject: $subject\n");
    $smtp->datasend("MIME-Version: 1.0\n");
    $smtp->datasend("Content-Type: text/html; charset=UTF-8\n");
    $smtp->datasend("Content-Transfer-Encoding: 8bit\n");
    $smtp->datasend("\n");
    $smtp->datasend($html_body);

    if (!$smtp->dataend) {
	$log->error("fetchconfig::Mailer: SMTP server $host:$port did not accept mail body for <" . join('>,<', @rcpt_list) . ">");
	$smtp->quit;
	return;
    }

    $smtp->quit;

    $log->info("fetchconfig::Mailer: sent backup summary (" . scalar(@rcpt_list) . " recipient(s)): " . join(', ', @rcpt_list));
}

#
# Builds and sends the end-of-run summary e-mail(s). No-op (no SMTP
# connection at all) unless an "email:" line was parsed and no
# devices were recorded via record_result().
#
sub send_summaries {
    my ($class, $logger) = @_;

    $log = $logger if defined($logger);

    return unless $email_seen; # no "email:" configured at all - stay silent

    $log->info('-----[email]--------------------------------------------------------------------------------');

    if (@results < 1) {
	$log->debug("fetchconfig::Mailer: no devices processed - skipping backup summary email");
	return;
    }

    my $from      = $email_config{from};
    my $to        = $email_config{to};
    my $smtp_host = $email_config{smtp};

    if (!defined($from) || !defined($to) || !defined($smtp_host)) {
	$log->error("fetchconfig::Mailer: email: configuration incomplete (from=/to=/smtp= are mandatory) - skipping backup summary email");
	return;
    }

    my @global_rows = sort { $a->{dev_id} cmp $b->{dev_id} } @results;

    $class->send_mail($to,
		       'fetchconfig backup summary - ' . iso_date(time),
		       $class->build_report_html(\@global_rows, 'Status of all backups'));

    # Group devices whose recipient was overridden per-device; each
    # distinct override recipient gets its own mail with only its
    # own devices. Skip an override that's identical to the global
    # recipient: that address already received the full report above.
    my %override_groups;

    foreach my $row (@results) {
	my $override_to = $row->{to};

	next unless defined($override_to) && length(trim($override_to));
	next if lc(trim($override_to)) eq lc(trim($to));

	push @{$override_groups{$override_to}}, $row;
    }

    foreach my $override_to (sort keys %override_groups) {
	my @rows = sort { $a->{dev_id} cmp $b->{dev_id} } @{$override_groups{$override_to}};

	$class->send_mail($override_to,
			   'fetchconfig backup summary (your devices) - ' . iso_date(time),
			   $class->build_report_html(\@rows, 'Status of your backups'));
    }
}

1;

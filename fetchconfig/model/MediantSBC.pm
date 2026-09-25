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
# AudioCodes Mediant SBC / gateway with the current Cisco-style CLI
# (observed: Mediant 500Li, "Welcome to AudioCodes CLI"). This is NOT
# the older menu-style "/CONFiguration>" CLI handled by Mediant.pm; the
# two are different products in practice and both models are kept.
#
# From a real telnet capture and the maintainer's session notes:
#
#   Welcome to AudioCodes CLI
#   Username: <user>                (telnet only; SSH authenticates the
#   Password:                        user and lands on the prompt)
#   hostname> enable                 ">" is the unprivileged level
#   Password: <enable>
#   hostname# show running-config              non-default settings (default)
#    --MORE--                                   pager: driven, see below
#   # Running Configuration M500Li
#   ## Data Configuration
#   ...
#   hostname# exit
#
# Prompts carry a trailing space ("hostname> ", "hostname# "). Lines end
# in "\r\n" over SSH and "\r\r\n" over telnet (stripansi removes the CRs).
# The default command is the plain "show running-config" (settings that
# differ from the firmware defaults): it is the form the device's own
# CLI-script export produces and the one a restore (copy cli-script
# from ...) is designed for. "show running-config full" lists every
# parameter incl. defaults - valuable for auditing default changes
# across firmware upgrades, but riskier to replay on a newer firmware.
# Set show_cmd=show running-config full per device when the audit form
# is wanted (a second device entry with its own dev_id gives both).
#
# Pager: the CLI pauses with " --MORE--" after a screen of output. The
# pager settings live under "configure system" -> "cli-settings":
# default-window-height is PERSISTENT (all new sessions, survives a
# restart, part of the running configuration), and the per-session
# override window-height exists only inside that configuration mode.
# A backup tool must not modify the configuration and should not enter
# configuration mode on a production device at all, so the pager is
# driven: wait for either the prompt or the --MORE-- marker, send a
# space on the marker, strip the marker and the erase sequence the
# device sends after the keystroke, repeat. pager_cmd= can name a
# command to run before the show command instead (for a firmware that
# does offer a session-only setting); its rejection is detected.
#
# Transport is selected by the transport= option: "ssh" (default),
# "telnet", or "auto". "auto" tries SSH first and falls back to telnet
# ONLY if the TCP connection to the SSH port fails (no SSH service on the
# device). It never falls back on an authentication or protocol error:
# that would retry the password over a second channel (lockouts, alarms)
# and silently move a credential from an encrypted to a cleartext
# channel. A fallback is logged at info level so a downgrade is always
# visible.
#
# Options: user, pass, enable (all mandatory), transport (optional,
# default ssh), timeout, keep, changes_only, repository, fetch_timeout,
# banner_timeout, prompt_settle_ms (SSH, default 150 ms), show_cmd,
# pager_cmd (optional, see above), debug (writes <repository>/<dev_id>.debug,
# mode 0600).
#

package fetchconfig::model::MediantSBC; # fetchconfig/model/MediantSBC.pm

use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract; # base class

@fetchconfig::model::MediantSBC::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
    'mediant-sbc';
}

# The privileged prompt ends in "# " (trailing space). The "> " prompt is
# matched explicitly in chat_login with a per-call tail.
sub prompt_tail { '# $' }

# "sub new" fully inherited from fetchconfig::model::Abstract (it sets up
# default_options, which the default: lines of the device table fill).

sub fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    my $saved_prefix = $self->{log}->prefix; # save log prefix
    $self->{log}->prefix("$saved_prefix: dev=$dev_id host=$dev_host");

    my @conf = $self->do_fetch($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab);

    # restore log prefix
    $self->{log}->prefix($saved_prefix);

    return @conf;
}

#
# Implement model::Abstract - End
##################################

# Wait for the "> " or "# " command prompt after authentication. The
# token is one word (hostnames here are plain), the sign is captured so
# the caller knows which level it landed on.
sub wait_for_prompt {
    my ($self, $t, $dev_opt_tab) = @_;

    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, '/([\w.-]+)([>#]) $/');
    if (!defined($prematch)) {
	$self->log_error("could not find command prompt");
	return;
    }

    $match = fetchconfig::model::Abstract::stripansi($match);
    if ($match !~ /^([\w.-]+)([>#]) $/) {
	$self->log_error("could not parse command prompt: [$match]");
	return;
    }

    ($1, $2);
}

# Telnet login: "Username: " / "Password: ", then the prompt.
sub telnet_login {
    my ($self, $t, $dev_user, $dev_pass, $dev_opt_tab) = @_;

    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, '/Username: $/');
    if (!defined($prematch)) {
	$self->log_error("could not find login prompt: /Username: \$/");
	return 1;
    }
    $self->log_debug("found login prompt: [Username: ]");

    if (!$t->print($dev_user)) {
	$self->log_error("could not send login username");
	return 1;
    }

    ($prematch, $match) = $t->waitfor(Match => '/Password: $/');
    if (!defined($prematch)) {
	$self->log_error("could not find password prompt: /Password: \$/");
	return 1;
    }
    $self->log_debug("found password prompt: [Password: ]");

    if (!$self->print_secret($t, $dev_pass)) {
	$self->log_error("could not send login password");
	return 1;
    }

    0;
}

# From the "> " prompt: "enable", "Password: ", expect "# ".
sub chat_enable {
    my ($self, $t, $prompt, $dev_enable) = @_;

    if (!$t->print('enable')) {
	$self->log_error("could not send enable command");
	return 1;
    }

    my ($prematch, $match) = $t->waitfor(Match => '/Password: $/');
    if (!defined($prematch)) {
	$self->log_error("could not find enable password prompt: /Password: \$/");
	return 1;
    }
    $self->log_debug("found enable password prompt: [Password: ]");

    if (!$self->print_secret($t, $dev_enable)) {
	$self->log_error("could not send enable password");
	return 1;
    }

    # Either the privileged "# " prompt, or a rejection - observed on a
    # Mediant 500Li as:
    #     Password:
    #
    #     Access denied
    #
    #     SBC10>
    # Match both so a wrong enable password gives a clear message with
    # the device's own text rather than a timeout. The trailing space is
    # optional here only: both outcomes are terminal states.
    ($prematch, $match) = $t->waitfor(Match => '/' . fetchconfig::model::Abstract::regexp_quote_keep_bytes($prompt) . '[>#] ?$/');
    if (!defined($prematch)) {
	$self->log_error("could not find privileged prompt after enable");
	return 1;
    }
    $match = fetchconfig::model::Abstract::stripansi($match);
    if ($match !~ /#/) {
	my $said = fetchconfig::model::Abstract::stripansi($prematch);
	$said =~ s/^\s+|\s+$//g; $said =~ s/\s*\n\s*/ | /g;
	$self->log_error("enable rejected by the device" . ($said ne '' ? ": [$said]" : "") . " - check the enable password");
	return 1;
    }
    $self->log_debug("found enable prompt: [$match]");

    0;
}

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $pager_cmd, $conf_ref) = @_;

    my ($prematch, $match);

    # Optional session-only pager-off command (none known for this
    # firmware; kept for one that has it). A rejection aborts the fetch
    # rather than letting the show command hang at the first --MORE--.
    if (defined($pager_cmd)) {
	$self->log_debug("cmd: [$pager_cmd]");
	if (!$t->print($pager_cmd)) {
	    $self->log_error("could not send pager command");
	    return 1;
	}
	($prematch, $match) = $self->expect_enable_prompt($t, $prompt, undef, 'pager-cmd');
	return 1 unless defined($prematch);
	my $said = fetchconfig::model::Abstract::stripansi($prematch);
	if ($said =~ /\n\s*((?:%|Error|Invalid|Unknown|Unrecognized)[^\n]*)/i) {
	    $self->log_error("pager command rejected: [$1]");
	    return 1;
	}
    }

    if ($self->chat_show_conf($t, 'show running-config', $show_cmd)) {
	return 1;
    }

    my $save_timeout;
    if (defined($fetch_timeout)) {
	$save_timeout = $t->timeout;
	$t->timeout($fetch_timeout);
    }

    # Drive the pager. The prompt regex is the shared one (escape prefix,
    # byte-safe quoting, "# $"); the marker alternative is added here.
    my $prompt_re = $self->prompt_head . fetchconfig::model::Abstract::regexp_quote_keep_bytes($prompt) . $self->prompt_tail;
    my $pages = 0;
    my $raw = '';
    while (1) {
	($prematch, $match) = $t->waitfor(Match => '/' . $prompt_re . '|--MORE--/');
	if (!defined($prematch)) {
	    $self->log_error("could not find end of configuration" . ($pages ? " (after $pages pager page(s))" : ""));
	    $t->timeout($save_timeout) if defined($fetch_timeout);
	    return 1;
	}
	$raw .= $prematch;
	last if $match !~ /--MORE--/;
	# Page boundary. The marker's own leading space is the tail of
	# $prematch; the erase sequence the device sends after the keystroke
	# is the head of the next chunk. A sentinel byte (NUL, which the
	# device never sends - stripansi would remove a real one) marks the
	# spot so the cleanup below acts ONLY here, never on config text.
	$pages++;
	if (!$t->put(" ")) {
	    $self->log_error("could not continue pager output");
	    $t->timeout($save_timeout) if defined($fetch_timeout);
	    return 1;
	}
	$raw .= "\x00";
    }

    if (defined($fetch_timeout)) {
	$t->timeout($save_timeout);
    }

    $self->log_debug("found end of configuration: [" . fetchconfig::model::Abstract::stripansi($match) . "]" . ($pages ? " after $pages pager page(s)" : ""));

    # Remove pager residue at each page boundary only. Observed on the
    # Mediant 500Li (raw SSH capture): "...line\r\n --MORE--" then, after
    # the space, 9 backspaces, 9 spaces, 9 backspaces (erasing the marker)
    # and the next configuration line immediately, with no CR/LF in
    # between. At the sentinel we drop the spaces before it (the marker's
    # own leading space) and, after it, everything up to the next
    # configuration line's first non-erase byte: backspaces, CRs and
    # spaces, but NOT the "\n" that would mean the erase style ends its
    # own line, and never past a newline into content. This is exact for
    # the observed backspace style and for a CR+spaces+CR style, and it
    # cannot touch a configuration line's indentation or a legitimate
    # trailing space, because it only acts where a --MORE-- was seen.
    #
    # After the sentinel: backspaces and CRs are always erase bytes; a run
    # of spaces is erase only while a backspace or CR still follows it
    # (the 9 overwriting spaces sit between two backspace runs). The
    # spaces that begin the next configuration line are followed by text,
    # so the look-ahead leaves them alone - the raw capture shows the
    # last backspace immediately followed by "    jitter-buffer...".
    $raw =~ s/[ ]*\x00(?:\x08+|\r|[ ]+(?=[\x08\r]))*//g;
    $raw = fetchconfig::model::Abstract::stripansi($raw);
    @$conf_ref = split /\n/, $raw;

    while (@$conf_ref && $conf_ref->[0] !~ /^# Running Configuration/) {
	shift @$conf_ref;
    }
    if (!@$conf_ref) {
	$self->log_error("could not find start of configuration (no \"# Running Configuration\" line)");
	return 1;
    }
    while (@$conf_ref && $conf_ref->[-1] =~ /^\s*$/) {
	pop @$conf_ref;
    }

    $self->log_debug("start of configuration: [$conf_ref->[0]]");
    $self->log_debug("fetched: " . scalar @$conf_ref . " lines");

    undef;
}

sub chat_logout {
    my ($self, $t) = @_;
    $t->print('exit');
    $self->log_debug("logged out");
}

# Telnet connection (used when transport=telnet, or as the auto fallback).
sub telnet_open {
    my ($self, $dev_host, $dev_timeout, $debug_path) = @_;

    my @telnet_args = (Errmode => 'return', Timeout => $dev_timeout);
    push @telnet_args, (dump_log => $debug_path) if defined($debug_path);
    my $t = Net::Telnet->new(@telnet_args);
    $self->secure_debug_file($debug_path) if defined($debug_path);

    my ($host, $port) = ($dev_host, 23);
    if ($dev_host =~ /^(.+):(\d+)$/) { ($host, $port) = ($1, $2); }

    if (!$t->open(Host => $host, Port => $port)) {
	$self->log_error("could not connect (telnet): " . $t->errmsg);
	return;
    }
    $t;
}

sub do_fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    $self->log_debug("trying");

    my $dev_repository = $self->dev_option($dev_opt_tab, "repository");
    if (!defined($dev_repository)) {
	$self->log_error("undefined repository");
	return;
    }

    my $dev_user = $self->dev_option($dev_opt_tab, "user");
    my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
    my $dev_enable = $self->dev_option($dev_opt_tab, "enable");
    foreach my $need ([user => $dev_user], [pass => $dev_pass], [enable => $dev_enable]) {
	if (!defined($need->[1])) {
	    $self->log_error("$need->[0] needed but not provided");
	    return;
	}
    }

    my $dev_timeout = $self->dev_option($dev_opt_tab, "timeout");
    my $fetch_timeout = $self->dev_option($dev_opt_tab, "fetch_timeout");
    my $show_cmd = $self->dev_option($dev_opt_tab, "show_cmd");
    my $pager_cmd = $self->dev_option($dev_opt_tab, "pager_cmd");

    my $transport = lc($self->dev_option($dev_opt_tab, "transport") // 'ssh');
    if ($transport !~ /^(ssh|telnet|auto)$/) {
	$self->log_error("transport must be ssh, telnet or auto (got '$transport')");
	return;
    }

    my $settle = $self->dev_option($dev_opt_tab, "prompt_settle_ms");
    if (defined($settle) && $settle !~ /^\d+$/) {
	$self->log_error("prompt_settle_ms must be a number of milliseconds: $settle");
	return;
    }
    $self->{prompt_settle_ms} = defined($settle) ? $settle : 150;

    my ($t, $ssh, $pid, $warn_guard);
    my $used = $transport;

    if ($transport eq 'ssh' || $transport eq 'auto') {
	my $debug_fh = $self->open_ssh_debug_file($dev_opt_tab, $dev_repository, $dev_id, $dev_host);
	($t, $ssh, $pid, $warn_guard) = $self->ssh_open($dev_host, $dev_user, $dev_pass, $dev_timeout, $debug_fh);
	if (!defined($t)) {
	    return unless $transport eq 'auto';
	    # auto: fall back to telnet ONLY when there is no SSH service
	    # to talk to (connection refused / unreachable / timed out
	    # before any SSH exchange). ssh_open already logged the error.
	    my $err = $self->{last_ssh_error} // '';
	    # Net::OpenSSH reports both a refused connection and a bad
	    # password as OSSH_MASTER_FAILED, so the error TEXT is the only
	    # signal. These are the phrasings OpenSSH uses when no service
	    # answered; anything else (auth, kex, host key, protocol) is not
	    # a reason to try the password again over cleartext.
	    if ($err !~ /Connection refused|Network is unreachable|No route to host|Connection timed out|timed out while waiting|Operation timed out|Could not resolve hostname|Name or service not known|kex_exchange_identification: read: Connection reset/i) {
		$self->log_error("transport=auto: not falling back to telnet - the SSH failure was not a connection failure");
		return;
	    }
	    $self->log_info("transport=auto: no SSH service reachable, falling back to telnet (cleartext)");
	    $used = 'telnet';
	}
	else {
	    $used = 'ssh';
	}
    }

    if ($used eq 'telnet') {
	my $debug_path = $self->dev_option_flag($dev_opt_tab, "debug", 0) ? "$dev_repository/$dev_id.debug" : undef;
	$t = $self->telnet_open($dev_host, $dev_timeout, $debug_path);
	return unless defined($t);
	$self->log_debug("connected (telnet)");
	return if $self->telnet_login($t, $dev_user, $dev_pass, $dev_opt_tab);
    }

    my ($prompt, $sign) = $self->wait_for_prompt($t, $dev_opt_tab);
    return unless defined($prompt);
    $self->log_debug("found command prompt: [$prompt$sign ]");

    if ($sign eq '>') {
	return if $self->chat_enable($t, $prompt, $dev_enable);
    }
    else {
	$self->log_debug("already privileged");
    }
    $self->{prompt} = $prompt;
    $self->log_debug("logged in prompt=[$prompt]");

    my @config;
    if ($self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $pager_cmd, \@config)) {
	$self->chat_logout($t);
	$t->close;
	waitpid($pid, 0) if defined($pid);
	return;
    }

    $self->chat_logout($t);
    $t->close;
    waitpid($pid, 0) if defined($pid);
    $self->log_debug("disconnected");

    $self->dump_config($dev_id, $dev_opt_tab, \@config);
}

1;

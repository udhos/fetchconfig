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
# PLANET managed switches (observed: IGS-4215-16P2T2S, firmware
# v3.0.5) over SSH. The CLI is Cisco-IOS-like ("terminal length 0",
# "show running-config", ">" user / "#" privileged prompt, "enable"),
# so this module follows CiscoIOSSSH.pm: the shell is driven through a
# pseudo-terminal from Net::OpenSSH (open2pty), handed to Net::Telnet
# for the prompt handling. Two things are PLANET-specific, both taken
# from a real PuTTY session log:
#
#   - after the SSH authentication the switch runs its OWN login
#     dialog on top: a "Welcome to Layer 2 Managed Switch" banner,
#     "Press <Enter> to continue...", a screen clear (ESC[H ESC[J) and
#     then "Username: " / "Password: " again. chat_login answers all
#     of them, in whatever subset a firmware presents, before looking
#     for the command prompt. If the switch lands on the ">" prompt,
#     "enable" is sent; the enable password is the "enable" option, or
#     the login password when no "enable" option is given (the
#     observed device uses the same one).
#   - "show running-config" opens with a header block, "SYSTEM CONFIG
#     FILE ::= BEGIN" followed by "! System ..." comment lines, one of
#     which is the uptime ("! System Up Time: 458 days, 23 hours, ...")
#     and therefore different on every run. The header is kept in the
#     backup (it identifies model and firmware), but config_equal is
#     overridden so the uptime line alone never counts as a change.
#
# Session ends with "exit" (back to ">") and "exit" (disconnect), as
# in the captured session. The prompt is "<hostname># " with a
# trailing space, hence the " ?$" in the prompt patterns.
#
# Change: 20260909a (Rainer) the first live run failed to log in. Its
#         dump_log looked like a switch that could not take input
#         arriving as a burst right after a prompt (letters of the
#         first "admin<CR>" apparently dropped, the password echoed
#         partly as asterisks and partly in clear), and slow_print()
#         plus the "type_delay" option were added on that reading.
#         The failure of that particular run was a typo in the
#         configured password, and with the typo fixed the device
#         logged in at full speed (type_delay=0) once - but repeated
#         live runs showed that full speed is NOT reliable: the login
#         fails intermittently without the pauses and consistently
#         succeeds with them. So the burst sensitivity is real, just
#         not deterministic, and the default is type_delay=100: that
#         many milliseconds after each character, three times that
#         before the first one, for every line sent (credentials and
#         commands). type_delay=0 disables the pauses.
#
# Change: 20260909b (Rainer) a second PLANET variant (U-6121-SW1) has
#         no switch-side login dialog at all - SSH authentication, then
#         straight to the "#" prompt - and its "show running-config"
#         opens with "Building configuration..." instead of "SYSTEM
#         CONFIG FILE ::= BEGIN". The login loop already coped (it
#         answers only what appears), but chat_fetch insisted on the
#         BEGIN line as first line of the config. Now a leading
#         "Building configuration..." and blank lines are discarded
#         (the same banner Zyxel.pm drops, and not part of the config
#         the device would restore from), and the only hard checks
#         left are "not empty" and "not a % CLI error".
# Change: 20260909c (Rainer) the same variant (IGS-5225-8P4S) closes
#         the SSH session on the FIRST "exit" - there is no ">" level
#         to fall back to - so chat_logout's wait for the ">" prompt
#         ended in EOF and an error was logged after a successful
#         backup. chat_logout now takes either answer to the first
#         "exit": a ">" prompt (then a second "exit" is sent, as the
#         IGS-4215 needs) or the connection closing (logged out
#         already). Only a timeout with the session still open is an
#         error.
# Change: 20260910a (Rainer) the debug file started at the first byte
#         the switch sent after login, with nothing about the login
#         itself. Inherent to the design: SSH authentication is done
#         by the ssh client process Net::OpenSSH spawns, before
#         Net::Telnet (whose dump_log the debug file was) is attached
#         to the pty; and "login as:" is PuTTY's own prompt, not
#         anything the switch sends. What can be recorded is ssh's own
#         account of the authentication: with debug=on the master
#         connection now runs at LogLevel=DEBUG with its stderr
#         directed into the same debug file (master_stderr_fh), ahead
#         of the Net::Telnet session dump. The file then opens with
#         ssh's connect/key-exchange/authentication lines ("Authenti-
#         cation succeeded (password)" or the reason it didn't), then
#         the switch session. Without debug the master stays at
#         LogLevel=ERROR as before.
#
# $Id: PLANET.pm,v 1.7 2026/09/10 10:00:00 tammer Exp $

package fetchconfig::model::PLANET; # fetchconfig/model/PLANET.pm

use strict;
use warnings;
use Net::Telnet;
use Net::OpenSSH;
use IO::Handle;
use Time::HiRes qw(usleep);
use fetchconfig::model::Abstract;

@fetchconfig::model::PLANET::ISA = qw(fetchconfig::model::Abstract);

# Header line of "show running-config" that changes on every run and
# must not by itself count as a change (see header comment).
my $VOLATILE_LINE = qr/^! System Up Time:/;

# Default pause between characters typed to the switch, milliseconds
# (option "type_delay"); 0 = none, see Change: 20260909a.
my $DEFAULT_TYPE_DELAY_MS = 100;

####################################
# Implement model::Abstract - Begin
#

sub label {
    'planet-ssh';
}

# "sub new" fully inherited from fetchconfig::model::Abstract

sub fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    my $saved_prefix = $self->{log}->prefix; # save log prefix

    $self->{log}->prefix("$saved_prefix: dev=$dev_id host=$dev_host");

    my @conf = $self->do_fetch($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab);

    # restore log prefix
    $self->{log}->prefix($saved_prefix);

    @conf;
}

# The uptime header line is stripped from both files before comparing,
# same mechanism as CiscoASA.pm uses for its save-timestamp banner.
sub config_equal {
    my ($self, $prev_dir, $prev_file, $curr_dir, $curr_file) = @_;

    $self->config_equal_ignoring_lines($prev_dir, $prev_file, $curr_dir, $curr_file,
				       $VOLATILE_LINE);
}

#
# Implement model::Abstract - End
##################################

#
# Types $text to the switch the way a human would: a pause first, then
# one character per write with a pause after each, then CR - the
# switch does not reliably take a burst of input right after a prompt.
# With type_delay=0 there are no pauses and the effect is that of
# $t->print(). See Change: 20260909a. Returns true on success like
# print() does.
#
sub slow_print {
    my ($self, $t, $text) = @_;

    my $delay_us = $self->{type_delay_ms} * 1000;

    usleep(3 * $delay_us) if $delay_us;

    for my $c (split //, $text) {
	return 0 unless $t->put($c);
	usleep($delay_us) if $delay_us;
    }

    $t->put("\r");
}

sub chat_login {
    my ($self, $t, $dev_id, $dev_host, $dev_opt_tab) = @_;

    my $ok;

    my $dev_user = $self->dev_option($dev_opt_tab, "user");
    my $dev_pass = $self->dev_option($dev_opt_tab, "pass");

    # Everything the switch may show between SSH authentication and
    # the command prompt, handled in a loop so a firmware that skips a
    # step still works: the "Press <Enter>" banner, then the switch's
    # own Username:/Password: dialog, then the prompt.
    # The prompt branch is a whole-line token that allows spaces and
    # non-ASCII (a hostname may contain both), bounded by [^\r\n] so it
    # cannot cross into another line, and ending in the prompt sign. It
    # is the LAST alternative, so the literal Username:/Password:/banner
    # branches match first; the "Press <Enter> to continue..." banner
    # ends in ".", not a prompt sign, so the token cannot match it.
    my $login_pattern = '/(Press <Enter> to continue\.*|Username:|Password:|[^\r\n]*[^\r\n\s>#][ ]*[>#]) ?$/';

    my ($prematch, $match);
    my $steps = 0;

    while (1) {
	if (++$steps > 6) {
	    $self->log_error("too many login steps waiting for command prompt");
	    return undef;
	}

	# chat_banner is used to allow temporary modification
	# of timeout throught the 'banner_timeout' option
	($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, $login_pattern);
	if (!defined($prematch)) {
	    $self->log_error("could not find login prompt or command prompt: $login_pattern");
	    return undef;
	}

	$match =~ s/\s+$//;

	if ($match =~ /^Press <Enter>/) {
	    $self->log_debug("found banner, pressing enter");
	    # A single CR; slow_print() with an empty string gives the
	    # pause first, then the CR.
	    $ok = $self->slow_print($t, '');
	    if (!$ok) {
		$self->log_error("could not answer banner");
		return undef;
	    }
	    next;
	}

	if ($match =~ /^Username:/) {
	    $self->log_debug("found username prompt");
	    $ok = $self->slow_print($t, $dev_user);
	    if (!$ok) {
		$self->log_error("could not send login username");
		return undef;
	    }
	    next;
	}

	if ($match =~ /^Password:/) {
	    $self->log_debug("found password prompt");
	    $ok = $self->slow_print($t, $dev_pass);
	    if (!$ok) {
		$self->log_error("could not send login password");
		return undef;
	    }
	    next;
	}

	last; # command prompt
    }

    $self->log_debug("found command prompt: [$match]");

    if ($match =~ /^.*[^\s>#][ ]*>$/) {
	$ok = $self->slow_print($t, 'enable');
	if (!$ok) {
	    $self->log_error("could not send enable command");
	    return undef;
	}

	($prematch, $match) = $t->waitfor(Match => '/(Password:|[^\r\n]*[^\r\n\s>#][ ]*#) ?$/');
	if (!defined($prematch)) {
	    $self->log_error("could not find enable password prompt");
	    return undef;
	}

	$match =~ s/\s+$//;

	if ($match =~ /^Password:/) {
	    # The observed device uses the login password for enable;
	    # an explicit "enable" option wins when given.
	    my $dev_enable = $self->dev_option($dev_opt_tab, "enable");
	    $dev_enable = $dev_pass unless defined($dev_enable);

	    $ok = $self->slow_print($t, $dev_enable);
	    if (!$ok) {
		$self->log_error("could not send enable password");
		return undef;
	    }

	    ($prematch, $match) = $t->waitfor(Match => '/[^\r\n]*[^\r\n\s>#][ ]*# ?$/');
	    if (!defined($prematch)) {
		$self->log_error("could not find enable command prompt (wrong enable password?)");
		return undef;
	    }

	    $match =~ s/\s+$//;
	}

	$self->log_debug("found enable prompt: [$match]");
    }

    if ($match !~ /^(.*[^\s>#])[ ]*\#$/) {
	$self->log_error("could not match enable command prompt");
	return undef;
    }

    my $prompt = $1;

    # Normalize to raw bytes in case the device table was read as UTF-8
    # (see Abstract::regexp_quote_keep_bytes).
    utf8::encode($prompt) if utf8::is_utf8($prompt);

    $self->{prompt} = $prompt; # save prompt

    $self->log_debug("logged in prompt=[$prompt]");

    $prompt;
}

# expect_enable_prompt: inherited from model::Abstract since 9.58; this model's device fact is below.
sub prompt_tail { '# ?$' }

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;

    my $ok;

    # Full command as in the captured session, not Cisco's "term len 0".
    $ok = $self->slow_print($t, 'terminal length 0');
    if (!$ok) {
	$self->log_error("could not send pager disabling command");
	return 1;
    }

    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return 1 unless defined($prematch);

    # Full command as in the captured session; overridable via show_cmd=.
    # Not Abstract::chat_show_conf(), which uses $t->print(); all input
    # to this device goes through slow_print() so that type_delay, if
    # set, applies to it too (see Change: 20260909a).
    my $cmd = defined($show_cmd) ? $show_cmd : 'show running-config';
    $self->log_debug("cmd: [$cmd]");
    if (!$self->slow_print($t, $cmd)) {
	$self->log_error("could not send show config command: $cmd");
	return 1;
    }

    # Prevent "show running-config" command echo from appearing in the
    # config dump.
    $t->getline();

    my $save_timeout;
    if (defined($fetch_timeout)) {
	$save_timeout = $t->timeout;
	$t->timeout($fetch_timeout);
    }

    ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    if (!defined($prematch)) {
	$self->log_error("could not find end of configuration");
	return 1;
    }

    if (defined($fetch_timeout)) {
	$t->timeout($save_timeout);
    }

    $self->log_debug("found end of configuration: [$match]");

    # Strip any "\r" the pty may have left, then split; split /\n/
    # drops the empty trailing fields, i.e. the blank line(s) the
    # switch prints before the prompt.
    $prematch =~ s/\r//g;
    @$conf_ref = split /\n/, $prematch;

    # Some firmware opens with "Building configuration..." (and a blank
    # line), others go straight to "SYSTEM CONFIG FILE ::= BEGIN"; see
    # Change: 20260909b. The banner is not config, drop it.
    while (@$conf_ref && ($conf_ref->[0] =~ /^Building configuration/i || $conf_ref->[0] =~ /^\s*$/)) {
	shift @$conf_ref;
    }

    if (!@$conf_ref) {
	$self->log_error("empty configuration");
	return 1;
    }

    if ($conf_ref->[0] =~ /^%/) {
	$self->log_error("show command rejected: [$conf_ref->[0]]");
	return 1;
    }

    $self->log_debug("start of configuration: [$conf_ref->[0]]");

    $self->log_debug("fetched: " . scalar @$conf_ref . " lines");

    undef;
}

sub chat_logout {
    my ($self, $t) = @_;

    # Two firmware behaviours on "exit" from "#" (see Change:
    # 20260909c): the IGS-4215 drops to ">" and needs a second "exit"
    # to disconnect; the IGS-5225 disconnects right away. Nothing is
    # waited for after a disconnecting "exit"; the peer closes the
    # channel.
    if (!$self->slow_print($t, 'exit')) {
	$self->log_error("could not send exit command");
	return;
    }

    my ($prematch, $match) = $t->waitfor(Match => '/[^\r\n]*[^\r\n\s>#][ ]*> ?$/');

    if (!defined($prematch)) {
	if ($t->eof) {
	    $self->log_debug("logged out (session closed on exit)");
	    return;
	}
	$self->log_error("could not find user prompt after exit");
	return;
    }

    if (!$self->slow_print($t, 'exit')) {
	$self->log_error("could not send second exit command");
	return;
    }

    $self->log_debug("logged out");
}

sub do_fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    $self->log_debug("trying");

    my $dev_repository = $self->dev_option($dev_opt_tab, "repository");
    if (!defined($dev_repository)) {
	$self->log_error("undefined repository");
	return;
    }

    if (! -d $dev_repository) {
	$self->log_error("not a directory repository=$dev_repository at file=$file line=$line_num: $line");
	return;
    }

    if (! -w $dev_repository) {
	$self->log_error("unable to write to repository=$dev_repository at file=$file line=$line_num: $line");
	return;
    }

    # SSH requires the username and password up front; the same two
    # are then fed to the switch's own Username:/Password: dialog.
    my $dev_user = $self->dev_option($dev_opt_tab, "user");
    if (!defined($dev_user)) {
	$self->log_error("login username needed but not provided");
	return;
    }

    my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
    if (!defined($dev_pass)) {
	$self->log_error("login password needed but not provided");
	return;
    }

    my $dev_timeout = $self->dev_option($dev_opt_tab, "timeout");

    # SSH connection, pty and Net::Telnet wrapper: shared implementation in
    # model::Abstract (ssh_open) since 9.59. debug=on writes <repository>/<dev_id>.debug
    # (0600): the ssh client's -v trace, then the session dump.
    my $debug_fh = $self->open_ssh_debug_file($dev_opt_tab, $self->dev_option($dev_opt_tab, "repository"), $dev_id, $dev_host);
    my ($t, $ssh, $pid, $warn_guard) = $self->ssh_open($dev_host, $dev_user, $dev_pass, $dev_timeout, $debug_fh);
    return unless defined($t);

    # Optional typing pace for this device (see Change: 20260909a).
    my $type_delay = $self->dev_option($dev_opt_tab, "type_delay");
    if (defined($type_delay) && $type_delay !~ /^\d+$/) {
	$self->log_error("type_delay must be a number of milliseconds: $type_delay");
	return;
    }
    $self->{type_delay_ms} = defined($type_delay) ? $type_delay : $DEFAULT_TYPE_DELAY_MS;

    my $prompt = $self->chat_login($t, $dev_id, $dev_host, $dev_opt_tab);
    return unless defined($prompt);

    my @config;

    my $fetch_timeout = $self->dev_option($dev_opt_tab, "fetch_timeout");
    my $show_cmd = $self->dev_option($dev_opt_tab, "show_cmd");

    return if $self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, \@config);

    $self->chat_logout($t);

    my $ok = $t->close;
    if (!$ok) {
	$self->log_error("disconnecting: $!");
    }

    # Reap the ssh child; the master connection is torn down when $ssh
    # goes out of scope at the end of this sub.
    waitpid($pid, 0) if defined($pid);

    $self->log_debug("disconnected");

    $self->dump_config($dev_id, $dev_opt_tab, \@config);
}

1;

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
# Modeled after model::CiscoIOS.pm, for Zyxel switches over telnet/SSH
# (observed hostname format "U-105E-101-SW1", with Zyxel-specific
# config directives like "loop-protect" and "ringv2 protect group"),
# based on a real SecureCRT-captured login/show-running-config
# session. The CLI closely mirrors Cisco IOS conventions (same
# Username:/Password: login, "!"-separated config sections, "end" to
# close the config), which is why CiscoIOS.pm serves well as a
# template - login (chat_login) and end-of-config detection
# (expect_enable_prompt) are reused unchanged. Three things differ,
# all confirmed directly from real device output (a second sample,
# hostname "RGS200-12P", showing the "enable"-with-password path the
# first session didn't exercise):
#   - the pager-disabling and show commands are spelled out in full,
#     "terminal length 0" and "show running-config", rather than
#     Cisco's usual abbreviated "term len 0"/"show run" - no evidence
#     either abbreviation is accepted here, so the exact working
#     commands are used instead of assuming abbreviation works
#   - every prompt-terminating regex tolerates an optional trailing
#     space rather than requiring or forbidding one: the first
#     session's prompts consistently end "...# " (confirmed from its
#     raw bytes), while the second sample's end "...#"/"...Password:"
#     with none at all - two real devices, two conventions, so
#     neither is assumed to hold universally
#   - the "Building configuration..." banner is followed immediately
#     by real config content that does NOT necessarily start with
#     "version " or "!" (e.g. "hostname ..."), unlike Cisco IOS's own
#     "Building configuration...\r\n\r\nCurrent configuration : NNNN
#     bytes\r\n!\r\nversion ..." - CiscoIOS.pm's top_info loop, which
#     anchors on "version "/"!", would otherwise misidentify several
#     leading real config lines as noise. Only the banner line itself
#     (and, defensively, a blank line) is treated as noise here.
#
# $Id: Zyxel.pm,v 1.1 2026/09/07 13:00:00 tammer Exp $

package fetchconfig::model::Zyxel; # fetchconfig/model/Zyxel.pm

use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract;

@fetchconfig::model::Zyxel::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
    'zyxel';
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

#
# Implement model::Abstract - End
##################################

#
# Login flow follows CiscoIOS.pm's structure closely: Username:/
# Password: prompts, then either a "#" prompt directly (an account
# with full privilege, as in the first captured session) or a ">"
# prompt needing "enable" (+ its own Password: prompt) to reach "#",
# as in a second sample (hostname "RGS200-12P"). Both paths are
# confirmed working against real device output.
#
# Every prompt-terminating regex here tolerates an OPTIONAL trailing
# space rather than requiring or forbidding one: the first captured
# session's prompts consistently end "...# " (confirmed from its raw
# bytes), while the second sample's end "...#"/"...Password:" with no
# trailing space at all. Rather than assume either convention holds
# across all Zyxel firmware, every match here accepts both.
#
sub chat_login {
    my ($self, $t, $dev_id, $dev_host, $dev_opt_tab) = @_;
    my $ok;

    my $login_prompt = '/(Username:|Password:) ?$/';

    # chat_banner is used to allow temporary modification
    # of timeout throught the 'banner_timeout' option

    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, $login_prompt);
    if (!defined($prematch)) {
	$self->log_error("could not find login prompt: $login_prompt");
	return undef;
    }

    $self->log_debug("found login prompt: [$match]");

    if ($match =~ /^Username/) {
	my $dev_user = $self->dev_option($dev_opt_tab, "user");
	if (!defined($dev_user)) {
	    $self->log_error("login username needed but not provided");
	    return undef;
	}

	$ok = $t->print($dev_user);
	if (!$ok) {
	    $self->log_error("could not send login username");
	    return undef;
	}

	($prematch, $match) = $t->waitfor(Match => '/Password: ?$/');
	if (!defined($prematch)) {
	    $self->log_error("could not find password prompt");
	    return undef;
	}

	$self->log_debug("found password prompt: [$match]");
    }

    if ($match =~ /^Password/) {
	my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
        if (!defined($dev_pass)) {
	    $self->log_error("login password needed but not provided");
	    return undef;
        }

	$ok = $t->print($dev_pass);
	if (!$ok) {
	    $self->log_error("could not send login password");
	    return undef;
	}

        ($prematch, $match) = $t->waitfor(Match => '/(\S+)[>#] ?$/');
	if (!defined($prematch)) {
	    $self->log_error("could not find command prompt");
	    return undef;
	}

	$self->log_debug("found command prompt: [$match]");
    }

    if ($match =~ /^\S+> ?$/) {
        $ok = $t->print('enable');
	if (!$ok) {
	    $self->log_error("could not send enable command");
	    return undef;
	}

        ($prematch, $match) = $t->waitfor(Match => '/(Password:|\S+#) ?$/');
	if (!defined($prematch)) {
	    $self->log_error("could not find enable password prompt");
	    return undef;
	}

        if ($match =~ /^Password/) {
	    my $dev_enable = $self->dev_option($dev_opt_tab, "enable");
	    if (!defined($dev_enable)) {
		$self->log_error("enable password needed but not provided");
		return undef;
	    }

	    $ok = $t->print($dev_enable);
	    if (!$ok) {
		$self->log_error("could not send enable password");
		return undef;
	    }

	    ($prematch, $match) = $t->waitfor(Match => '/\S+# ?$/');
	    if (!defined($prematch)) {
		$self->log_error("could not find enable command prompt");
		return undef;
	    }
        }

	$self->log_debug("found enable prompt: [$match]");
    }

    if ($match !~ /^(\S+)\# ?$/) {
	$self->log_error("could not match enable command prompt");
	return undef;
    }

    my $prompt = $1;

    $self->{prompt} = $prompt; # save prompt

    $self->log_debug("logged in prompt=[$prompt]");

    $prompt;
}

# expect_enable_prompt is identical to CiscoIOS.pm's: end-of-config
# detection just waits for the same "hostname#" prompt to reappear,
# confirmed directly in the captured session ("...end\r\nU-105E-101-SW1# ").
# expect_enable_prompt: inherited from model::Abstract since 9.58; this model's device fact is below.
sub prompt_tail { '# ?$' }

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;
    my $ok;

    # Full command, not Cisco's abbreviated "term len 0" - confirmed
    # from the captured session; no evidence the abbreviation works
    # on this device.
    $ok = $t->print('terminal length 0');
    if (!$ok) {
	$self->log_error("could not send pager disabling command");
	return 1;
    }

    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return unless defined($prematch);

    # Full command, not Cisco's abbreviated "show run" - same reason
    # as above. Still overridable per-device via show_cmd=.
    if ($self->chat_show_conf($t, 'show running-config', $show_cmd)) {
	return 1;
    }

    # Prevent "show running-config" command from appearing in config dump
    $t->getline();

    # Change: 20260908a (Rainer) a real debug trace (dump_log) showed
    # this device sends "\n\r" at the end of every line - LF then CR,
    # the REVERSE of the usual "\r\n" - confirmed directly from the
    # raw bytes ("...end\n\rU-105E-101-SW1# "). Net::Telnet's built-in
    # CRLF handling only collapses "\r\n" into a single "\n"; it does
    # not recognize the reversed order, so every line after the first
    # keeps a stray leading "\r" once split on "\n". Left alone, that
    # leading "\r" makes the "Building configuration" check below
    # never match (the line actually starts "\rBuilding
    # configuration...", not "Building configuration..."), and later
    # renders as what looks like an extra blank line in most viewers,
    # which is what was reported. "\r" is stripped explicitly instead
    # of relying on Net::Telnet's own translation, both here (so the
    # checks below match) and again on the final captured text below.

    # Discard the "Building configuration..." banner (and any blank
    # line before real content starts) entirely, rather than keeping
    # it "!!"-commented the way CiscoIOS.pm keeps its own preamble:
    # unlike Cisco's preamble (which can carry useful info such as
    # "Current configuration : NNNN bytes"), this banner carries
    # nothing worth preserving, and the device confirmed it isn't
    # part of the config the device itself would restore from.
    my $line;
    while ($line = $t->getline()) {
	$line =~ s/\r//g;
	next if $line =~ /^Building configuration/i || $line =~ /^\s*$/;
	last;
    }

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

    # Strip any remaining "\r" (see Change: 20260908a above) before
    # splitting into lines, then defensively drop any entirely blank
    # line left over, wherever it came from: this device's config
    # format uses "!" as its own section separator and has no
    # legitimate use for a blank line, so one appearing anywhere here
    # is noise, not real content.
    (my $clean = $line . $prematch) =~ s/\r//g;
    @$conf_ref = grep { length($_) } split /\n/, $clean;

    $self->log_debug("fetched: " . scalar(@$conf_ref) . " lines");

    undef;
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

    my $dev_timeout = $self->dev_option($dev_opt_tab, "timeout");

    my @telnet_args = (Errmode => 'return', Timeout => $dev_timeout);

    # Record the raw session for debugging. Written under the
    # device's own repository (same place its config backups live)
    # instead of a fixed, shared, world-readable /tmp path: avoids
    # leaking credentials/config to other local users and avoids a
    # predictable-filename symlink-attack target in /tmp. Off by
    # default; enable per-device with "debug=on" in the device table
    # (same convention as ProCurve.pm).
    if ($self->dev_option_flag($dev_opt_tab, "debug", 0)) {
	push @telnet_args, (dump_log => "$dev_repository/$dev_id.debug");
    }

    my $t = new Net::Telnet(@telnet_args);
    # dump_log records the session verbatim, credentials included -> 0600.
    # Net::Telnet opened the file in new(), so restrict it by path now.
    $self->secure_debug_file("$dev_repository/$dev_id.debug")
	if $self->dev_option_flag($dev_opt_tab, "debug", 0);

    my $ok = $t->open($dev_host);
    if (!$ok) {
	$self->log_error("could not connect: $!");
	return;
    }

    $self->log_debug("connected");

    my $prompt = $self->chat_login($t, $dev_id, $dev_host, $dev_opt_tab);

    return unless defined($prompt);

    my @config;

    my $fetch_timeout = $self->dev_option($dev_opt_tab, "fetch_timeout");

    my $show_cmd = $self->dev_option($dev_opt_tab, "show_cmd");

    return if $self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, \@config);

    $ok = $t->close;
    if (!$ok) {
	$self->log_error("disconnecting: $!");
    }

    $self->log_debug("disconnected");

    $self->dump_config($dev_id, $dev_opt_tab, \@config);
}

1;

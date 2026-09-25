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
# Modeled after model::CiscoIOS.pm, for Hirschmann Railswitch devices
# accessed over telnet (e.g. "Railswitch Release L2E-06.0.03"), based
# on a putty log capturing a real login/show-running-config session.
# Login/prompt shape observed there, differing from CiscoIOS.pm:
#   - Login prompts are "User:" and "Password:" (no trailing space,
#     unlike Cisco's "Username: "/"Password: ").
#   - The command prompt is "(<system name>) >" (unprivileged) or
#     "(<system name>) #" (privileged) - parentheses around the
#     configurable system name (which may itself contain spaces,
#     e.g. "Hirschmann Railswitch"), then a space, then ">" or "#".
#   - "enable" does not ask for a password: it goes straight from
#     ">" to "#". (Handled defensively below in case some other
#     firmware version does prompt for one, same as CiscoIOS.pm does
#     for Cisco's enable password - but per that observed session,
#     the plain, no-password path is what's expected here.)
#   - "show running-config all" was NOT observed to hit a pager
#     ("--More--" or similar) despite a long (500+ line) config, so,
#     unlike CiscoIOS.pm's "term len 0", no pager-disabling command
#     is sent here. If a pager prompt does turn out to be needed on
#     some other Hirschmann firmware/config size, this is the first
#     place to add it.
#   - Privilege persists past "show running-config all": the same
#     "(<system name>) #" prompt reappears at the end of the output,
#     same as CiscoIOS.pm expects for Cisco's "show run".
#   - Real config content starts with a comment line, "!..." (e.g.
#     "!Current Configuration:"), with a couple of blank/header lines
#     before it - handled the same way CiscoIOS.pm handles Cisco's
#     "Building configuration..."/"Current configuration : NNN
#     bytes" preamble: prefixed with "!!" and kept (not discarded),
#     so nothing is lost, just clearly marked as not part of the
#     device's own config.
#
# $Id: Hirschmann.pm,v 1.0 2026/09/02 12:00:00 tammer Exp $

package fetchconfig::model::Hirschmann; # fetchconfig/model/Hirschmann.pm

use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract;

@fetchconfig::model::Hirschmann::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
    'hirschmann';
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

sub chat_login {
    my ($self, $t, $dev_id, $dev_host, $dev_opt_tab) = @_;
    my $ok;

    my $login_prompt = '/(User:|Password:) ?$/';

    # chat_banner is used to allow temporary modification
    # of timeout throught the 'banner_timeout' option

    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, $login_prompt);
    if (!defined($prematch)) {
	$self->log_error("could not find login prompt: $login_prompt");
	return undef;
    }

    $self->log_debug("found login prompt: [$match]");

    if ($match =~ /^User:/) {
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

    if ($match =~ /^Password:/) {
	my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
	if (!defined($dev_pass)) {
	    $self->log_error("login password needed but not provided");
	    return undef;
	}

	$ok = $self->print_secret($t, $dev_pass);
	if (!$ok) {
	    $self->log_error("could not send login password");
	    return undef;
	}

	($prematch, $match) = $t->waitfor(Match => '/\(([^)]*)\)\s?[>#]$/');
	if (!defined($prematch)) {
	    $self->log_error("could not find command prompt");
	    return undef;
	}

	$self->log_debug("found command prompt: [$match]");
    }

    if ($match !~ /\(([^)]*)\)\s?([>#])$/) {
	$self->log_error("could not match command prompt: [$match]");
	return undef;
    }

    my $prompt      = $1; # system name only, e.g. "Hirschmann Railswitch"
    my $prompt_char = $2;

    if ($prompt_char eq '>') {
	# Send "enable" and, per the observed session, expect to land
	# straight on the "#" prompt with no password prompt in
	# between - but still tolerate one, defensively, in case some
	# other firmware version does ask (same pattern CiscoIOS.pm
	# uses for Cisco's own enable password).
	$ok = $t->print('enable');
	if (!$ok) {
	    $self->log_error("could not send enable command");
	    return undef;
	}

	my $enable_prompt_regexp = '/(Password: ?|\(' . quotemeta($prompt) . '\)\s?#)$/';

	($prematch, $match) = $t->waitfor(Match => $enable_prompt_regexp);
	if (!defined($prematch)) {
	    $self->log_error("could not find enable prompt");
	    return undef;
	}

	if ($match =~ /^Password:/) {
	    my $dev_enable = $self->dev_option($dev_opt_tab, "enable");
	    if (!defined($dev_enable)) {
		$self->log_error("enable password needed but not provided");
		return undef;
	    }

	    $ok = $self->print_secret($t, $dev_enable);
	    if (!$ok) {
		$self->log_error("could not send enable password");
		return undef;
	    }

	    ($prematch, $match) = $t->waitfor(Match => '/\(' . quotemeta($prompt) . '\)\s?#$/');
	    if (!defined($prematch)) {
		$self->log_error("could not find enable command prompt");
		return undef;
	    }
	}

	$self->log_debug("found enable prompt: [$match]");
    }

    $self->{prompt} = $prompt; # save prompt (system name only, no parens/state char)

    $self->log_debug("logged in prompt=[$prompt]");

    $prompt;
}

#
# Waits for the privileged ("#") prompt to reappear - used both right
# after sending "enable" and after "show running-config all"
# completes, since privilege persists past that command (the same
# "(<system name>) #" prompt reappears at the end of the output).
#
# expect_enable_prompt: inherited from model::Abstract since 9.58; this model's device fact is below.
sub prompt_head { '\(' }
sub prompt_tail { '\)\s?#$' }

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;

    if ($self->chat_show_conf($t, 'show running-config all', $show_cmd)) {
	return 1;
    }

    # Prevent "show running-config all" command from appearing in config dump
    $t->getline();

    # Comment out garbage at top so config file can be restored
    # cleanly at a later date
    my ($line, $top_info);
    while ($line = $t->getline()) {
	# Failsafe: just in case "!Current Configuration:" doesn't
	# appear, assume config begins at the first comment line ("!").
	if ($line =~ /^\!/) {
	    $top_info .= $line;
	    last;
	}
	else {
	    $top_info .= '!!' . $line;
	}
	# Normally, finding the "!Current Configuration:" line will
	# be enough to exit this loop.
	last if $line =~ /^!Current Configuration/i;
    }

    my $save_timeout;
    if (defined($fetch_timeout)) {
	$save_timeout = $t->timeout;
	$t->timeout($fetch_timeout);
    }

    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    if (!defined($prematch)) {
	$self->log_error("could not find end of configuration");
	return 1;
    }

    if (defined($fetch_timeout)) {
	$t->timeout($save_timeout);
    }

    $self->log_debug("found end of configuration: [$match]");

    @$conf_ref = split /\n/, $top_info . $prematch;

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

    my $t = new Net::Telnet(Errmode => 'return', Timeout => $dev_timeout);

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

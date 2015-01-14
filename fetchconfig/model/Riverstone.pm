# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2007 Everton da Silva Marques
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
# $Id: Riverstone.pm,v 1.1 2007/07/17 15:05:50 evertonm Exp $

package fetchconfig::model::Riverstone; # fetchconfig/model/Riverstone.pm

use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract;

@fetchconfig::model::Riverstone::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
    'riverstone';
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

    my $banner = '/Press RETURN to activate console \. \. \./';

    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, $banner);
    if (!defined($prematch)) {
	$self->log_error("could not find banner: $banner");
	return undef;
    }

    $self->log_debug("found banner: [$match]");

    $ok = $t->print('');
    if (!$ok) {
	$self->log_error("could not send ENTER");
	return undef;
    }

    ($prematch, $match) = $t->waitfor(Match => '/(Username:|Password:|\S+>|\S+#) $/');
    if (!defined($prematch)) {
	$self->log_error("could not find login prompt");
	return undef;
    }

    if ($match =~ /^Username:/) {
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

	($prematch, $match) = $t->waitfor(Match => '/(Password:|\S+>|\S+#) $/');
	if (!defined($prematch)) {
	    $self->log_error("could not find after-login prompt");
	    return undef;
	}

	$self->log_debug("found after-login prompt: [$match]");
    }

    if ($match =~ /^Password:/) {
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

	($prematch, $match) = $t->waitfor(Match => '/(\S+>|\S+#) $/');
	if (!defined($prematch)) {
	    $self->log_error("could not find command prompt");
	    return undef;
	}

	$self->log_debug("found command prompt: [$match]");
    }

    if ($match =~ /^\S+> $/) {
        $ok = $t->print('enable');
	if (!$ok) {
	    $self->log_error("could not send enable command");
	    return undef;
	}

	($prematch, $match) = $t->waitfor(Match => '/(Password:|\S+#) $/');
	if (!defined($prematch)) {
	    $self->log_error("could not find after-enable-command prompt");
	    return undef;
	}

	$self->log_debug("found after-enable-command prompt: [$match]");

	if ($match eq 'Password: ') {
	    $self->log_debug("found enable password prompt: [$match]");

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

	    ($prematch, $match) = $t->waitfor(Match => '/\S+# $/');
	    if (!defined($prematch)) {
		$self->log_error("could not find enable command prompt");
		return undef;
	    }

	    $self->log_debug("found after-enable-password prompt: [$match]");
	}
    }

    if ($match !~ /^(\S+)# $/) {
        $self->log_error("could not find enable command prompt");
        return undef;
    }

    my $prompt = $1;

    $self->{prompt} = $prompt; # save prompt

    $self->log_debug("logged in prompt=[$prompt]");

    $prompt;
}

sub expect_enable_prompt {
    my ($self, $t, $prompt, $label) = @_;

    if (!defined($prompt)) {
	$self->log_error("internal failure: undefined command prompt");
	return undef;
    }

    my $enable_prompt_regexp = '/' . $prompt . '# $/';

    my ($prematch, $match) = $t->waitfor(Match => $enable_prompt_regexp);
    if (!defined($prematch)) {
	$self->log_error("$label: could not match enable command prompt: $enable_prompt_regexp");
    }

    ($prematch, $match);
}

sub expect_config_prompt {
    my ($self, $t, $prompt, $label) = @_;

    if (!defined($prompt)) {
	$self->log_error("internal failure: undefined command prompt");
	return undef;
    }

    my $config_prompt_regexp = '/' . $prompt . '\(config\)# $/';

    my ($prematch, $match) = $t->waitfor(Match => $config_prompt_regexp);
    if (!defined($prematch)) {
	$self->log_error("$label: could not match config prompt: $config_prompt_regexp");
    }

    ($prematch, $match);
}

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $conf_ref) = @_;
    my $ok;
    
    my $show_cmd = 'system show active-config';

    $ok = $t->print($show_cmd);
    if (!$ok) {
	$self->log_error("could not send show run command: $show_cmd");
	return 1;
    }

    my $save_timeout;
    if (defined($fetch_timeout)) {
        $save_timeout = $t->timeout;
        $t->timeout($fetch_timeout);
    }

    my ($prematch, $match);
    ($prematch, $match) = $self->expect_enable_prompt($t, $prompt, 'fetching-config');
    if (!defined($prematch)) {
	$self->log_error("could not find end of configuration");
	return 1;
    }

    if (defined($fetch_timeout)) {
        $t->timeout($save_timeout);
    }

    $self->log_debug("found end of configuration: [$match]");

    @$conf_ref = split /\n/, $prematch;

    $self->log_debug("fetched: " . scalar @$conf_ref . " lines");

    undef;
}

sub chat_conf_mode_enter {
    my ($self, $t, $prompt) = @_;

    my $ok = $t->print('conf');
    if (!$ok) {
	$self->log_error("could not send config mode command");
	return 1;
    }

    my ($prematch, $match) = $self->expect_config_prompt($t, $prompt, 'entering-config-mode');
    if (!defined($prematch)) {
	$self->log_error("could not find after-config-commmand prompt");
	return 1;
    }

    $self->log_debug("entered config mode");

    undef;
}

sub chat_conf_mode_exit {
    my ($self, $t, $prompt) = @_;

    my $ok;

    $ok = $t->print('exit');
    if (!$ok) {
	$self->log_error("could not send config exit command");
	return 1;
    }

    $ok = $t->print('');
    if (!$ok) {
	$self->log_error("could not send ENTER");
	return 1;
    }

    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt, 'exiting-config-mode');
    if (!defined($prematch)) {
	$self->log_error("could not find after-config-exit-commmand command prompt");
	return 1;
    }

    $self->log_debug("exited config mode");

    undef;
}

sub chat_pager_off {
    my ($self, $t, $prompt) = @_;

    if ($self->chat_conf_mode_enter($t, $prompt)) {
	return 1;
    }

    my $ok = $t->print('system set terminal rows 0');
    my ($prematch, $match) = $self->expect_config_prompt($t, $prompt, 'disabling-pager');
    if (!defined($prematch)) {
	$self->log_error("could not send disable pager command");
	return 1;
    }

    $self->log_debug("pager disabled");

    if ($self->chat_conf_mode_exit($t, $prompt)) {
	return 1;
    }

    undef; # success
}

sub chat_pager_on {
    my ($self, $t, $prompt) = @_;

    if ($self->chat_conf_mode_enter($t, $prompt)) {
	return 1;
    }

    my $ok = $t->print('no system set terminal rows 0');
    my ($prematch, $match) = $self->expect_config_prompt($t, $prompt, 'enabling-pager');
    if (!defined($prematch)) {
	$self->log_error("could not send disable pager command");
	return 1;
    }

    $self->log_debug("pager enabled");

    if ($self->chat_conf_mode_exit($t, $prompt)) {
	return 1;
    }

    undef; # success
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

    if ($self->chat_pager_off($t, $prompt)) {
	$self->log_error("could not disable pager");
	return;
    }

    my @config;

    my $fetch_timeout = $self->dev_option($dev_opt_tab, "fetch_timeout");

    return if $self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, \@config);

    if ($self->chat_pager_on($t, $prompt)) {
	$self->log_error("could not re-enable pager");
    }

    $ok = $t->close;
    if (!$ok) {
	$self->log_error("disconnecting: $!");
    }

    $self->log_debug("disconnected");

    $self->dump_config($dev_id, $dev_opt_tab, \@config);
}

1;


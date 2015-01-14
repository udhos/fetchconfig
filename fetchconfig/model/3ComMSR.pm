# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2006 Everton da Silva Marques
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
# $Id: 3ComMSR.pm,v 1.1 2010/10/07 16:10:25 evertonm Exp $

package fetchconfig::model::3ComMSR; # fetchconfig/model/3ComMSR.pm

use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract;

@fetchconfig::model::3ComMSR::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
    '3com-msr';
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

    my $login_prompt = '/(Username:|Password:)$/';

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

	($prematch, $match) = $t->waitfor(Match => '/Password:$/');
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

        ($prematch, $match) = $t->waitfor(Match => '/<([^<>]+)>$/');
	if (!defined($prematch)) {
	    $self->log_error("could not find command prompt");
	    return undef;
	}

	$self->log_debug("found command prompt: [$match]");
    }

    if ($match =~ /^<([^<>]+)>$/) {
        $ok = $t->print('super');
	if (!$ok) {
	    $self->log_error("could not send enable command (super)");
	    return undef;
	}
	
        ($prematch, $match) = $t->waitfor(Match => '/(Password:|<([^<>]+)>)$/');
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

	    ($prematch, $match) = $t->waitfor(Match => '/<([^<>]+)>$/');
	    if (!defined($prematch)) {
		$self->log_error("could not find enable command prompt");
		return undef;
	    }
        }

	$self->log_debug("found enable prompt: '$match'");
    }

    if ($match =~ /^<([^<>]+)>$/) {
        $ok = $t->print('sys');
	if (!$ok) {
	    $self->log_error("could not send system-view command");
	    return undef;
	}
	
        ($prematch, $match) = $t->waitfor(Match => '/\[([^\[\]]+)\]$/');
	if (!defined($prematch)) {
	    $self->log_error("could not find system-view prompt");
	    return undef;
	}

	$self->log_debug("found system-view prompt: '$match'");
    }

    if ($match !~ /^\[([^\[\]]+)\]$/) {
	$self->log_error("could not match system-view prompt");
	return undef;
    }

    my $prompt = $1;

    $self->{prompt} = $prompt; # save prompt

    $self->log_debug("logged in prompt='$prompt'");

    $prompt;
}

sub expect_enable_prompt {
    my ($self, $t, $prompt) = @_;

    if (!defined($prompt)) {
	$self->log_error("internal failure: undefined command prompt");
	return undef;
    }

    my $enable_prompt_regexp = '/\[' . $prompt . '[^\[\]]*\]$/';

    my ($prematch, $match) = $t->waitfor(Match => $enable_prompt_regexp);
    if (!defined($prematch)) {
	$self->log_error("could not match enable command prompt: $enable_prompt_regexp");
    }

    ($prematch, $match);
}

sub pager_off {
    my ($self, $t, $dev_id, $dev_host, $prompt) = @_;
    my $ok;

    $ok = $t->print('user-interface vty 0 4');
    if (!$ok) {
	$self->log_error("could not send pager disabling command: user-interface vty 0 4");
	return 1;
    }
    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return 1 unless defined($prematch);

    $ok = $t->print('screen-length 0');
    if (!$ok) {
	$self->log_error("could not send pager disabling command: screen-length 0");
	return 1;
    }
    ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return 1 unless defined($prematch);

    $ok = $t->print('quit');
    if (!$ok) {
	$self->log_error("could not send pager disabling command: quit");
	return 1;
    }
    ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return 1 unless defined($prematch);

    undef;
}

sub pager_on {
    my ($self, $t, $dev_id, $dev_host, $prompt) = @_;
    my $ok;

    $ok = $t->print('user-interface vty 0 4');
    if (!$ok) {
	$self->log_error("could not send pager enabling command: user-interface vty 0 4");
	return 1;
    }
    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return 1 unless defined($prematch);

    $ok = $t->print('undo screen-length');
    if (!$ok) {
	$self->log_error("could not send pager enabling command: undo screen-length");
	return 1;
    }
    ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return 1 unless defined($prematch);

    $ok = $t->print('quit');
    if (!$ok) {
	$self->log_error("could not send pager enabling command: quit");
	return 1;
    }
    ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return 1 unless defined($prematch);

    undef;
}

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;
    my $ok;

    # disable pager
    if ($self->pager_off($t, $dev_id, $dev_host, $prompt)) {
	return 1;
    }

    # issue show run cmd
    if ($self->chat_show_conf($t, 'disp curr', $show_cmd)) {
	return 1;
    }

    # override default timeout with fetch_timeout, if defined
    my $save_timeout;
    if (defined($fetch_timeout)) {
        $save_timeout = $t->timeout;
        $t->timeout($fetch_timeout);
    }

    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    my $config_result = !defined($prematch);
    if ($config_result) {
	$self->log_error("could not find end of configuration");
    }

    # restore overriden timeout
    if (defined($fetch_timeout)) {
        $t->timeout($save_timeout);
    }

    # restore pager
    $self->pager_on($t, $dev_id, $dev_host, $prompt);

    return $config_result if $config_result;

    $self->log_debug("found end of configuration: '$match'");

    @$conf_ref = split /\n/, $prematch;

    $self->log_debug("fetched: " . scalar @$conf_ref . " lines");

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

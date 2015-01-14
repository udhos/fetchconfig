# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2013 Everton da Silva Marques
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
# $Id: Acme.pm,v 1.1 2013/10/16 03:29:11 evertonm Exp $

package fetchconfig::model::Acme; # fetchconfig/model/Acme.pm

use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract;

@fetchconfig::model::Acme::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
    'acme';
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

    my $login_prompt = '/(Username:|Password:) $/';

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

	($prematch, $match) = $t->waitfor(Match => '/Password: $/');
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

        ($prematch, $match) = $t->waitfor(Match => '/(\S+)[>#] $/');
	if (!defined($prematch)) {
	    $self->log_error("could not find command prompt");
	    return undef;
	}

	$self->log_debug("found command prompt: [$match]");
    }

    if ($match !~ /^(\S+)[>#] $/) {
	$self->log_error("could not match command prompt");
	return undef;
    }

    my $prompt = $1;

    $self->{prompt} = $prompt; # save prompt

    $self->log_debug("logged in prompt=[$prompt]");

    $prompt;
}

sub expect_enable_prompt {
    my ($self, $t, $prompt, $delim) = @_;

    if (!defined($prompt)) {
	$self->log_error("internal failure: undefined command prompt");
	return undef;
    }

    my $enable_prompt_regexp = '/' . $prompt . $delim . '/';

    my ($prematch, $match) = $t->waitfor(Match => $enable_prompt_regexp);
    if (!defined($prematch)) {
	$self->log_error("could not match enable command prompt: $enable_prompt_regexp");
    }

    ($prematch, $match);
}

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;
    my $ok;
    
    my ($prematch, $match);

    if ($self->chat_show_conf($t, 'show conf', $show_cmd)) {
	return 1;
    }

    my $save_timeout;
    if (defined($fetch_timeout)) {
        $save_timeout = $t->timeout;
        $t->timeout($fetch_timeout);
    }

    ($prematch, $match) = $self->expect_enable_prompt($t, $prompt, '[#>]');
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

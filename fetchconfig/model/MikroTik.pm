# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2010 Everton da Silva Marques
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
# $Id: MikroTik.pm,v 1.2 2010/12/02 19:50:37 evertonm Exp $

package fetchconfig::model::MikroTik; # fetchconfig/model/MikroTik.pm

use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract;

@fetchconfig::model::MikroTik::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
    'mikrotik';
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

    my $login_prompt = '/Login: $/';

    # chat_banner is used to allow temporary modification
    # of timeout throught the 'banner_timeout' option

    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, $login_prompt);
    if (!defined($prematch)) {
	$self->log_error("could not find login prompt: $login_prompt");
	return undef;
    }

    $self->log_debug("found login prompt: [$match]");

    my $dev_user = $self->dev_option($dev_opt_tab, "user");
    if (!defined($dev_user)) {
	$self->log_error("login username needed but not provided");
	return undef;
    }

    # Append +ct console login options to username:
    # c: disable console colors
    # t: Do auto detection of terminal capabilities
    #
    # Source:
    # http://wiki.mikrotik.com/wiki/Console_login_process#Console_login_options
    #
    my $user = "$dev_user+ct";
    $self->log_debug("sending user='$user'");

    $ok = $t->print($user);
    if (!$ok) {
	$self->log_error("could not send login username: '$user'");
	return undef;
    }

    ($prematch, $match) = $t->waitfor(Match => '/Password: $/');
    if (!defined($prematch)) {
	$self->log_error("could not find password prompt");
	return undef;
    }

    $self->log_debug("found password prompt: [$match]");

    my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
    if (!defined($dev_pass)) {
	$self->log_error("login password needed but not provided");
	return undef;
    }

    #$self->log_debug("sending password: '$dev_pass'");

    $ok = $t->print($dev_pass);
    if (!$ok) {
	$self->log_error("could not send login password");
	return undef;
    }

    ($prematch, $match) = $t->waitfor(Match => '/(\S+) > $/');
    if (!defined($prematch)) {
	$self->log_error("could not find command prompt");
	return undef;
    }

    my $prompt = $match;

    $self->log_debug("logged in prompt='$prompt'");

    $self->{prompt} = $prompt; # save prompt

    $prompt;
}

sub expect_enable_prompt {
    my ($self, $t, $prompt) = @_;

    if (!defined($prompt)) {
	$self->log_error("internal failure: undefined command prompt");
	return undef;
    }

    my $enable_prompt_regexp = '/' . $prompt . ' > $/';

    my ($prematch, $match) = $t->waitfor(Match => $enable_prompt_regexp);
    if (!defined($prematch)) {
	$self->log_error("could not match enable command prompt: $enable_prompt_regexp");
    }

    ($prematch, $match);
}

sub escape_brackets {
    my ($str) = @_;

    $str =~ s/\@/\\\@/g;
    $str =~ s/\[/\\\[/g;
    $str =~ s/\]/\\\]/g;

    $str;
}

sub expect_enable_prompt_paging {
    my ($self, $t, $prompt, $paging_prompt) = @_;

    if (!defined($prompt)) {
	$self->log_error("internal failure: undefined command prompt");
	return undef;
    }

    my $escaped_prompt = &escape_brackets($prompt);
    $self->log_debug("regexp='$prompt' escaped_brackets='$escaped_prompt'");

    my $prompt_regexp = '/(' . $escaped_prompt . ')|(' . $paging_prompt . ')/';
    my $paging_prompt_regexp = '/' . $paging_prompt . '/';

    my ($prematch, $match, $full_prematch);

    for (;;) {
	($prematch, $match) = $t->waitfor(Match => $prompt_regexp);
	if (!defined($prematch)) {
	    $self->log_error("could not match enable/paging prompt: $prompt_regexp");
	    return; # signals error with undef
	}

	#$self->log_debug("paging match: [$match]");

	$full_prematch .= $prematch;

	if ($match ne $paging_prompt) {
	    #$self->log_debug("done paging match: [$match][$paging_prompt_regexp]");
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

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;
    my ($ok, $prematch, $match);
    
    #$t->input_log(\*STDERR);

    if ($self->chat_show_conf($t, 'export', $show_cmd)) {
	return 1;
    }

    # Prevent "show run" command from appearing in config dump
    #$t->getline();

    my $save_timeout;
    if (defined($fetch_timeout)) {
        $save_timeout = $t->timeout;
        $t->timeout($fetch_timeout);
    }

    ($prematch, $match) = $self->expect_enable_prompt_paging($t, $prompt, '--More-- ');
    if (!defined($prematch)) {
	$self->log_error("could not find end of configuration");
	return 1;
    }

    if (defined($fetch_timeout)) {
        $t->timeout($save_timeout);
    }

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

    my $tm = $t->telnetmode(1);
    $self->log_debug("telnet command interpretation was: " . ($tm ? "on" : "off"));

    my $ok = $t->open($dev_host);
    if (!$ok) {
	$self->log_error("could not connect: $!");
	return;
    }

    $self->log_debug("connected");

    $tm = $t->telnetmode();
    $self->log_debug("telnet command interpretation is: " . ($tm ? "on" : "off"));

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

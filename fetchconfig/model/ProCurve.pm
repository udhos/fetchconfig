# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2006 Doug Schaapveld
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
# $Id: ProCurve.pm,v 1.4 2007/01/12 20:11:08 djschaap Exp $

package fetchconfig::model::ProCurve; # fetchconfig/model/ProCurve.pm

use strict;
use warnings;
use fetchconfig::model::Abstract;

@fetchconfig::model::ProCurve::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
	'procurve';
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

# There's probably a better way to do this, but this works for now!
# http://en.wikipedia.org/wiki/ANSI_escape_code
sub stripansi ($) {
	my $str=shift;
	$str=~s/\x1b\[\d*;?\d*[A-Za-z]//g;
	$str=~s/\x1b\[\?\d+[h]//g;  # What is this code? HP ProCurves use it
	$str=~s/\x1bE//g;  # HP ProCurves use this, too
	$str=~s/\x0d//g;
	$str;
}

sub chat_login_telnet {
	my ($self, $t, $dev_id, $dev_host, $dev_opt_tab) = @_;
	my $ok;

#	my ($prematch, $match) = $t->waitfor(Match => '/(Username:|Password:) $/');
#	my ($prematch, $match) = $t->waitfor(Match => '/Password: $/');
	my ($prematch, $match) = $t->waitfor(Match => '/Password: |Press any key to continue/');
	if (!defined($prematch)) {
		$self->log_error("could not find login prompt");
		return undef;
	}

	$self->log_debug("found login prompt: [$match]");

	if ($match =~ /Press any key to continue/) {
		$ok = $t->print("\n");
		if (!$ok) {
			$self->log_error("could not send any key");
			return undef;
		}

		($prematch, $match) = $t->waitfor(Match => '/([A-Za-z0-9-]+ ?)[>#] /');
		if (!defined($prematch)) {
			$self->log_error("could not find command prompt (nopw)");
			return undef;
		}

		# Note that below line may not appear properly due to the
		# escape sequences from the switch
		$self->log_debug("found command prompt: [$match]");
	}

	if ($match =~ /login: $/) {
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

	if ($match =~ /^Password: /) {
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

		($prematch, $match) = $t->waitfor(Match => '/([A-Za-z0-9-]+ ?)[>#] /');
		if (!defined($prematch)) {
			$self->log_error("could not find command prompt (pw)");
			return undef;
		}

		# Note that below line may not appear properly due to the
		# escape sequences from the switch
		$self->log_debug("found command prompt: [$match]");
	}

	if ($match !~ /^(\S+ ?)[>#] $/) {
		$self->log_error("could not match command prompt in [$match]");
		return undef;
	}

	if ($match =~ /^(\S+ ?)> $/) {
		$ok = $t->print('enable');
		if (!$ok) {
			$self->log_error("could not send enable command");
			return undef;
		}
	
		($prematch, $match) = $t->waitfor(Match => '/Password: /');
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

			($prematch, $match) = $t->waitfor(Match => '/([A-Za-z0-9-]+ ?)# /');
			if (!defined($prematch)) {
				$self->log_error("could not find enable command prompt");
				return undef;
			}
		}

		$self->log_debug("found enable prompt: [$match]");
	}

	if ($match !~ /([A-Za-z0-9-]+ ?)#/) {
		$self->log_error("could not match enable command prompt");
		return undef;
	}

	my $prompt = $1;

	$self->{prompt} = $prompt; # save prompt

	$self->log_debug("logged in prompt: [$prompt]");

	$prompt;
}

sub expect_enable_prompt {
	my ($self, $t, $prompt) = @_;

	if (!defined($prompt)) {
		$self->log_error("internal failure: undefined command prompt");
		return undef;
	}

	my $enable_prompt_regexp = '/' . $prompt . '# /';

    my ($prematch, $match) = $t->waitfor(Match => $enable_prompt_regexp);
	if (!defined($prematch)) {
		$self->log_error("could not match enable command prompt: $enable_prompt_regexp");
	}

	($prematch, $match);
}

sub chat_fetch {
	my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $conf_ref) = @_;
	my $ok;
    
	$ok = $t->print('no page');
	if (!$ok) {
		$self->log_error("could not send pager disabling command");
		return 1;
	}

	my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
	return unless defined($prematch);

	my $show_cmd="show run";

	$ok = $t->print($show_cmd);
	if (!$ok) {
		$self->log_error("could not send show run command: $show_cmd");
		return 1;
	}

	# Prevent "show run" command and "Running configuration"
	# from appearing in config dump
	$t->getline();
	$t->getline();
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

	foreach my $line (split /\n/, $prematch) {
		my $ascii_line=stripansi($line);
		chomp $ascii_line;
		push(@$conf_ref,$ascii_line ? $ascii_line : "");
	}

	# Remove ANSI fragment from final line (if present)
	$conf_ref->[$#$conf_ref]=~s/\x1b\[24\;//;

	# Debugging code for line-by-line analysis
#	for(my $i=0;$i<(scalar @$conf_ref);$i++) {
#		if((my $line_len=length $conf_ref->[$i]) >1) {
#			$self->log_debug("[L " . $i . "-" . (length $conf_ref->[$i]) . "] " . $conf_ref->[$i]);
#		}
#	}

	$self->log_debug("fetched: " . scalar @$conf_ref . " lines");

	return undef;
}

sub do_fetch_telnet {
	my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

	my $dev_timeout = $self->dev_option($dev_opt_tab, "timeout");

	my $t = new Net::Telnet(Errmode => 'return', Timeout => $dev_timeout);

	my $ok = $t->open($dev_host);
	if (!$ok) {
		$self->log_error("could not connect: $!");
		return;
	}

	$self->log_debug("connected");

	my $prompt = $self->chat_login_telnet($t, $dev_id, $dev_host, $dev_opt_tab);

	return unless defined($prompt);

	my $conf_ref=[];

	my $fetch_timeout = $self->dev_option($dev_opt_tab, "fetch_timeout");

	return if $self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, $conf_ref);

	$ok = $t->close;
	if (!$ok) {
		$self->log_error("disconnecting: $!");
	}

	return $conf_ref;
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

	my $conf_ref;
	$conf_ref=$self->do_fetch_telnet($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab);

	$self->log_debug("disconnected");

	$self->dump_config($dev_id, $dev_opt_tab, $conf_ref);
}

1;

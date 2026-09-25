# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2009 rip@devco.net
# Copyright (C) 2006 Everton da Silva Marques
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
# SSH conversion: connects via Net::OpenSSH and drives the resulting
# pty through Net::Telnet, so the existing prompt-matching logic below
# keeps working unchanged. SSH authenticates the login username/password
# when the connection is opened, so the interactive Username:/Password:
# exchange is gone; the "enable" escalation (separate enable password)
# still happens over the CLI exactly as before, since the ASA doesn't
# expose privilege elevation as an SSH-layer concept.
#
# $Id: CiscoASASSH.pm,v 1.0 2026/08/24 12:00:00 tammer Exp $

package fetchconfig::model::CiscoASASSH; # fetchconfig/model/CiscoASASSH.pm
use strict;
use warnings;
use Net::Telnet;
use Net::OpenSSH;
use fetchconfig::model::Abstract;
@fetchconfig::model::CiscoASASSH::ISA = qw(fetchconfig::model::Abstract);
####################################
# Implement model::Abstract - Begin
#
sub label {
    'cisco-asa-ssh';
}

# Legacy crypto this switch family still needs (shared ssh_open adds them to master_opts).
sub ssh_extra_opts { (-o => "KexAlgorithms=+diffie-hellman-group1-sha1", -o => "HostKeyAlgorithms=+ssh-rsa", -o => "Ciphers=+aes128-cbc,3des-cbc") }
# "sub new" fully inherited from fetchconfig::model::Abstract
#
# The ASA rewrites its "!!: Written by <user> at <time> <tz> <weekday>
# <month> <day> <year>" banner line on every "show run", even when
# nothing else in the configuration changed. Ignore that one line
# when deciding whether the configuration actually changed.
#
sub config_equal {
    my ($self, $prev_dir, $prev_file, $curr_dir, $curr_file) = @_;

    $self->log_debug("ignore !!: Written by ...");

    $self->config_equal_ignoring_lines($prev_dir, $prev_file, $curr_dir, $curr_file,
					qr/^!!: Written by \S+ at /);
}
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
    # SSH authenticates the login username/password when the connection
    # is opened (see do_fetch), so there is no interactive
    # Username:/Password: exchange here. We wait directly for the
    # user-mode (>) or privileged (#) command prompt, then continue
    # with the existing enable escalation below.
    my $command_prompt = '/(\S+)[>#] $/';
    # chat_banner is used to allow temporary modification
    # of timeout throught the 'banner_timeout' option
    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, $command_prompt);
    if (!defined($prematch)) {
        $self->log_error("could not find command prompt: $command_prompt");
        return undef;
    }
    $self->log_debug("found command prompt: [$match]");
    if ($match =~ /^\S+> $/) {
        $ok = $t->print('enable');
        if (!$ok) {
            $self->log_error("could not send enable command");
            return undef;
        }
        ($prematch, $match) = $t->waitfor(Match => '/(Password: |\S+# )$/');
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
            $ok = $self->print_secret($t, $dev_enable);
            if (!$ok) {
                $self->log_error("could not send enable password");
                return undef;
            }
            ($prematch, $match) = $t->waitfor(Match => '/\S+# $/');
            if (!defined($prematch)) {
                $self->log_error("could not find enable command prompt");
                return undef;
            }
        }
        $self->log_debug("found enable prompt: [$match]");
    }
    if ($match !~ /^(\S+)\# $/) {
        $self->log_error("could not match enable command prompt ($match)");
        return undef;
    }
    my $prompt = $1;
    $self->{prompt} = $prompt; # save prompt
    $self->log_debug("logged in prompt=[$prompt]");
    $prompt;
}
# expect_enable_prompt: inherited from model::Abstract since 9.58; this model's device fact is below.
sub prompt_tail { '# $' }
sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;
    my $ok;
    $ok = $t->print('term pager 0');
    if (!$ok) {
        $self->log_error("could not send pager disabling command");
        return 1;
    }
    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
    return unless defined($prematch);
    # Backward compatibility support for option "show_cmd=wrterm"
    my $custom_cmd;
    if (defined($show_cmd)) {
        $custom_cmd = ($show_cmd eq 'wrterm') ? 'write term' : $show_cmd;
    }
    if ($self->chat_show_conf($t, 'more system:running-config', $custom_cmd)) {
        return 1;
    }
    # Prevent "show run" command from appearing in config dump
    $t->getline();
    # Commment out garbage at top so config file can be restored
    # cleanly at a later date
    my($line,$top_info);
    while($line=$t->getline()) {
         if($line=~/^\!/) {
             $top_info.=$line;
             last;
         } else {
             $top_info.='!!' . $line;
         }
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
    @$conf_ref = split /\n/, $top_info . $prematch;
    $self->log_debug("fetched: " . scalar @$conf_ref . " lines");
    return undef;
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
    # SSH requires the username (and normally the password) up front,
    # so both are resolved here instead of being fed to interactive
    # login prompts.
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
    my $prompt = $self->chat_login($t, $dev_id, $dev_host, $dev_opt_tab);
    return unless defined($prompt);
    my @config;
    my $fetch_timeout = $self->dev_option($dev_opt_tab, "fetch_timeout");
    my $show_cmd = $self->dev_option($dev_opt_tab, "show_cmd");
    return if $self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, \@config);
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


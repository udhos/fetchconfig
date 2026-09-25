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
# Aruba CX switches (AOS-CX; observed: PL.10.17) over SSH. Modeled on
# CiscoIOSSSH.pm - Net::OpenSSH pty driven through Net::Telnet - with
# the debug wiring of PLANET.pm. From a real PuTTY session log:
#
#   - SSH authentication lands directly on the "<hostname># " prompt
#     (trailing space), possibly after "Last login: ..." and a "User
#     ... has logged in N times" line. AOS-CX has no Cisco-style
#     "enable": an administrator gets "#" straight away, an operator
#     gets ">" and cannot show the running configuration, so a ">"
#     prompt is reported as an error rather than answered with
#     "enable".
#   - the pager is disabled with "no page" (not "terminal length 0").
#   - "show running-config" prints a "Current configuration:" header
#     line before the config proper, which starts with "!" and
#     "!Version AOS-CX ...". The header is dropped; the rest is stored
#     verbatim, including the version comment (it only changes with
#     a firmware upgrade - a real change).
#   - "exit" closes the SSH session directly.
#
# debug=on writes <repository>/<dev_id>.debug: first the ssh master
# connection's stderr at LogLevel=DEBUG (the SSH authentication, as
# the ssh client records it), then Net::Telnet's dump_log of the
# switch session - same layout as PLANET.pm.
#
# $Id: ArubaCXSSH.pm,v 1.1 2026/09/10 17:00:00 tammer Exp $

package fetchconfig::model::ArubaCXSSH; # fetchconfig/model/ArubaCXSSH.pm

use strict;
use warnings;
use Net::Telnet;
use Net::OpenSSH;
use IO::Handle;
use fetchconfig::model::Abstract;

@fetchconfig::model::ArubaCXSSH::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label {
    'aruba-cx-ssh';
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

    # Prompt token: the whole content of the LAST line, up to the
    # trailing prompt sign. [^\r\n] keeps the token on one line (so a
    # multi-line banner cannot be swallowed), and it deliberately
    # allows spaces and non-ASCII, because AOS-CX hostnames can contain
    # both (e.g. "apgmg01 UG IT-Buero"). The final char before the sign
    # must be non-space so trailing spaces are not captured. Anchored
    # at end of buffer.
    my $command_prompt = '/([^\r\n]*[^\r\n\s>#])[ ]*([>#]) ?$/';

    # Let output settle first: because the token is broad, matching it
    # against a still-streaming banner could latch onto a banner line
    # that happens to end in "#". Draining until the channel is idle
    # means the match sees the finished prompt as the last line.
    $self->drain_until_idle($t, $self->{prompt_settle_ms});

    # chat_banner is used to allow temporary modification
    # of timeout throught the 'banner_timeout' option
    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, $command_prompt);
    if (!defined($prematch)) {
	$self->log_error("could not find command prompt: $command_prompt");
	return undef;
    }

    $match =~ s/\s+$//;

    $self->log_debug("found command prompt: [$match]");

    if ($match =~ /^(.*[^\s>#])[ ]*>$/) {
	$self->log_error("operator prompt [$match]: the account cannot show the running configuration; use an administrator account");
	return undef;
    }

    if ($match !~ /^(.*[^\s>#])[ ]*\#$/) {
	$self->log_error("could not match command prompt");
	return undef;
    }

    my $prompt = $1;

    # The prompt may arrive with Perl's UTF-8 flag set (device table
    # read as UTF-8); normalize to raw bytes so it matches the byte
    # stream from the pty and logs consistently. See
    # Abstract::regexp_quote_keep_bytes.
    utf8::encode($prompt) if utf8::is_utf8($prompt);

    $self->{prompt} = $prompt; # save prompt

    $self->log_debug("logged in prompt=[$prompt]");

    $prompt;
}

sub expect_prompt {
    my ($self, $t, $prompt) = @_;

    if (!defined($prompt)) {
	$self->log_error("internal failure: undefined command prompt");
	return undef;
    }

    # Settle first, then match the full saved prompt literally
    # (regexp_quote_keep_bytes escapes only ASCII metacharacters, so the
    # spaces and the raw non-ASCII bytes in the prompt match literally).
    $self->drain_until_idle($t, $self->{prompt_settle_ms});

    my $prompt_regexp = '/' . fetchconfig::model::Abstract::regexp_quote_keep_bytes($prompt) . '# ?$/';

    my ($prematch, $match) = $t->waitfor(Match => $prompt_regexp);
    if (!defined($prematch)) {
	$self->log_error("could not match command prompt: $prompt_regexp");
    }

    ($prematch, $match);
}

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;

    my $ok;

    $ok = $t->print('no page');
    if (!$ok) {
	$self->log_error("could not send pager disabling command");
	return 1;
    }

    my ($prematch, $match) = $self->expect_prompt($t, $prompt);
    return 1 unless defined($prematch);

    if ($self->chat_show_conf($t, 'show running-config', $show_cmd)) {
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

    ($prematch, $match) = $self->expect_prompt($t, $prompt);
    if (!defined($prematch)) {
	$self->log_error("could not find end of configuration");
	return 1;
    }

    if (defined($fetch_timeout)) {
	$t->timeout($save_timeout);
    }

    $self->log_debug("found end of configuration: [$match]");

    # Strip any "\r" the pty may have left, then split; split /\n/
    # drops empty trailing fields.
    $prematch =~ s/\r//g;
    @$conf_ref = split /\n/, $prematch;

    # Drop the "Current configuration:" header and blank lines before
    # the first config line; the config proper starts with "!".
    while (@$conf_ref && ($conf_ref->[0] =~ /^Current configuration/i || $conf_ref->[0] =~ /^\s*$/)) {
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

    # "exit" closes the SSH session; nothing is waited for, the peer
    # closes the channel.
    if (!$t->print('exit')) {
	$self->log_error("could not send exit command");
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

    # SSH requires the username and password up front.
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

    # Milliseconds to wait for output to go idle before matching the
    # (space/Unicode-tolerant) command prompt; 0 disables. Default 150.
    my $settle = $self->dev_option($dev_opt_tab, "prompt_settle_ms");
    if (defined($settle) && $settle !~ /^\d+$/) {
	$self->log_error("prompt_settle_ms must be a number of milliseconds: $settle");
	return;
    }
    $self->{prompt_settle_ms} = defined($settle) ? $settle : 150;

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

# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2006 Doug Schaapveld
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
# SSH model for HPE/H3C Comware 7 switches (e.g. FlexNetwork / FlexFabric),
# derived from the ProCurveSSH model. Unlike ProCurve, Comware:
#   - shows a copyright banner and then a user-view prompt "<hostname>"
#     (no "Press any key to continue", no Username/Password re-prompt),
#   - needs no "enable" step (SSH auth lands you in user view already),
#   - disables pagination with "screen-length disable",
#   - dumps the running config with "display current-configuration".
#
# The device shell is driven through a pseudo-terminal provided by
# Net::OpenSSH (open2pty), handed to Net::Telnet so the prompt-matching
# logic works. SSH authenticates user/password when the connection is
# opened, so there is no interactive login exchange.

package fetchconfig::model::ComwareSSH; # fetchconfig/model/ComwareSSH.pm

use strict;
use warnings;
use Net::Telnet;
use Net::OpenSSH;
use fetchconfig::model::Abstract;

@fetchconfig::model::ComwareSSH::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

sub label
{
  'comware-ssh';
}

# Legacy crypto this switch family still needs (shared ssh_open adds them to master_opts).
sub ssh_extra_opts { (-o => "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1", -o => "HostKeyAlgorithms=+ssh-rsa", -o => "Ciphers=+aes128-cbc,3des-cbc") }

# "sub new" fully inherited from fetchconfig::model::Abstract

sub fetch
{
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

# Comware output is normally clean ASCII, but strip any stray carriage
# returns and generic ANSI escapes that may leak through the pty.
# stripansi: shared implementation in model::Abstract since 9.58.

sub chat_login {
  my ($self, $t, $dev_id, $dev_host, $dev_opt_tab) = @_;

  # Under SSH the username and password are supplied when the connection
  # is opened (see do_fetch_ssh). Comware prints a copyright banner and
  # then the user-view prompt "<hostname>". Wait for that prompt; the
  # banner (which contains no angle-bracket prompt) is skipped.
  my ($prematch, $match) = $t->waitfor(Match => '/<[\w.-]+>\s*$/');
  if (!defined($prematch))
  {
    $self->log_error("could not find command prompt");
    return undef;
  }
  else
  {
    $self->log_debug("found command prompt: [$match]");
  }

  # Extract the hostname from the "<hostname>" prompt.
  if ($match !~ /<([\w.-]+)>/)
  {
    $self->log_error("could not match command prompt in [$match]");
    return undef;
  }
  my $prompt = $1;
  $self->{prompt} = $prompt; # save prompt
  $self->log_debug("logged in prompt: [$prompt]");
  $prompt;
}

sub expect_prompt
{
  my ($self, $t, $prompt) = @_;
  if (!defined($prompt))
  {
    $self->log_error("internal failure: undefined command prompt");
    return undef;
  }
  # Comware user-view prompt is "<hostname>". quotemeta guards against
  # any regex metacharacter that might appear in the hostname.
  my $prompt_regexp = '/<' . quotemeta($prompt) . '>/';
  my ($prematch, $match) = $t->waitfor(Match => $prompt_regexp);
  if (!defined($prematch))
  {
    $self->log_error("could not match command prompt: $prompt_regexp");
  }
  ($prematch, $match);
}

sub chat_fetch
{
  my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $conf_ref) = @_;
  my $ok;

  # Disable pagination for this session.
  $ok = $t->print('screen-length disable');
  if (!$ok)
  {
    $self->log_error("could not send pager disabling command");
    return 1;
  }
  my ($prematch, $match) = $self->expect_prompt($t, $prompt);
  return unless defined($prematch);

  my $show_cmd = "display current-configuration";
  $ok = $t->print($show_cmd);
  if (!$ok)
  {
    $self->log_error("could not send show command: $show_cmd");
    return 1;
  }

  # Discard the echoed command line so it does not appear in the dump.
  $t->getline();

  my $save_timeout;
  if (defined($fetch_timeout))
  {
    $save_timeout = $t->timeout;
    $t->timeout($fetch_timeout);
  }

  ($prematch, $match) = $self->expect_prompt($t, $prompt);
  if (!defined($prematch))
  {
    $self->log_error("could not find end of configuration");
    return 1;
  }

  if (defined($fetch_timeout))
  {
    $t->timeout($save_timeout);
  }

  $self->log_debug("found end of configuration: [$match]");

  foreach my $line (split /\n/, $prematch)
  {
    my $ascii_line=fetchconfig::model::Abstract::stripansi($line);
    chomp $ascii_line;
    push(@$conf_ref,$ascii_line ? $ascii_line : "");
  }

  # Defensive cleanup: drop trailing blank lines and any leftover prompt
  # line (e.g. "<hostname>" or the system-view "[hostname]") that the pty
  # may append after the final "return" line.
  while (@$conf_ref && $conf_ref->[$#$conf_ref] =~ /^\s*$/)
  {
    pop @$conf_ref;
  }
  if (@$conf_ref && $conf_ref->[$#$conf_ref] =~ /^\s*[<\[]?\Q$prompt\E[>\]]?\s*$/)
  {
    pop @$conf_ref;
  }
  while (@$conf_ref && $conf_ref->[$#$conf_ref] =~ /^\s*$/)
  {
    pop @$conf_ref;
  }

  $self->log_debug("fetched: " . scalar @$conf_ref . " lines");
  return undef;
}

sub do_fetch_ssh
{
  my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

  # SSH requires the username (and normally the password) up front, so
  # both are resolved here instead of being fed to interactive prompts.
  my $dev_user = $self->dev_option($dev_opt_tab, "user");
  if (!defined($dev_user))
  {
    $self->log_error("login username needed but not provided");
    return;
  }

  my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
  if (!defined($dev_pass))
  {
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

  my $conf_ref=[];
  my $fetch_timeout = $self->dev_option($dev_opt_tab, "fetch_timeout");
  return if $self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, $conf_ref);

  my $ok = $t->close;
  if (!$ok)
  {
    $self->log_error("disconnecting: $!");
  }

  # Reap the ssh child; the master connection is torn down when $ssh
  # goes out of scope at the end of this sub.
  waitpid($pid, 0) if defined($pid);

  return $conf_ref;
}

sub do_fetch
{
  my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;
  $self->log_debug("trying");
  my $dev_repository = $self->dev_option($dev_opt_tab, "repository");
  if (!defined($dev_repository))
  {
    $self->log_error("undefined repository");
    return;
  }
  if (! -d $dev_repository)
  {
    $self->log_error("not a directory repository=$dev_repository at file=$file line=$line_num: $line");
    return;
  }
  if (! -w $dev_repository)
  {
    $self->log_error("unable to write to repository=$dev_repository at file=$file line=$line_num: $line");
    return;
  }
  my $conf_ref;
  $conf_ref=$self->do_fetch_ssh($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab);
  $self->log_debug("disconnected");
  # do_fetch_ssh returns undef on any login/fetch failure (see its
  # early "return;" points above). Belt-and-suspenders alongside the
  # same check now in Abstract::dump_config(): don't even attempt to
  # save, consistent with every other model's do_fetch().
  return unless defined($conf_ref);
  $self->dump_config($dev_id, $dev_opt_tab, $conf_ref);
}

1;


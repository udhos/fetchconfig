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
# Change: 20120117 (Tammer) make HP ProCurve work
# Change: (Tammer) converted from telnet to SSH
# Change: 20260821a (Rainer) some ProCurve/Aruba firmware (e.g. 2530
#         YA.16.11.0026) shows the "Press any key to continue" banner
#         twice in a row - once right after connecting, then again
#         after the "Your previous successful login..." notice -
#         before the real command prompt appears. chat_login only
#         handled a single banner occurrence, so the second banner was
#         mistaken for a failed wait ("could not find command prompt
#         after banner"). The single "hit a key, then expect prompt"
#         step is now a bounded loop that keeps expecting either
#         another banner or the prompt until the prompt shows up.
# Change: 20260821b (Rainer) sending a bare Return to dismiss that
#         banner is itself the trap: HP/Aruba documents that pressing
#         Return at "Press any key to continue" selects the built-in
#         ASCII Menu interface, while any other key drops straight
#         into the CLI. The banner-dismiss keystroke is now a single
#         space sent raw (Net::Telnet put(), no trailing CR/LF)
#         instead of print(""), which was appending "\r" via
#         Output_record_separator. As a safety net in case firmware or
#         config forces Menu mode regardless, chat_login also detects
#         the "Main Menu" screen and selects "5. Command Line (CLI)"
#         to drop back to the CLI before continuing.
# Change: 20260824 (Rainer) the ssh master process's own stderr was
#         leaking into the fetchconfig log: "Warning: Permanently
#         added ... to the list of known hosts" (printed on every run
#         because UserKnownHostsFile is /dev/null below, so ssh always
#         sees the host key as new) plus, on this switch, HP's
#         "please register your products" pre-auth SSH banner. Both
#         are ssh client-side notices at the default LogLevel=INFO,
#         not part of the device session (they never appear in
#         ssh.debug). Added LogLevel=ERROR to master_opts to silence
#         them while still surfacing genuine connect/auth errors that
#         $ssh->error() depends on.
# Change: 20260827 (Rainer) on V1-SW2 the "no page" command arrived at
#         the switch as "o page" ("Invalid input: o" in ssh.debug),
#         leaving the pager enabled, so "show run" hit a "-- MORE --"
#         prompt partway through and chat_fetch sat waiting for the
#         final command prompt that could never appear until the
#         pager was fed a keystroke - a silent hang up to
#         fetch_timeout, with a truncated config on expiry. Rather
#         than chase why the keystroke dropped, chat_fetch's
#         end-of-config wait now treats "-- MORE --" as an
#         interstitial prompt exactly like chat_login treats banners:
#         loop, send a raw space to page through, and keep
#         accumulating output until the real prompt shows up. This
#         makes the fetch resilient to paging regardless of whether
#         "no page" was accepted. The pager's own status line ("--
#         MORE --, next page: Space, next line: Enter, quit:
#         Control-C") is stripped from the saved lines so it can't
#         leak into the config as a bogus line.
# Change: 20260828a (Rainer) session debug logging (dump_log) is now
#         gated behind a new device table option, "debug=on" (default
#         off), via the shared Abstract::dev_option_flag() helper.
#         Also dropped the per-run timestamp from the debug log
#         filename: $dev_repository/$dev_id.$debug_ts.debug is now
#         $dev_repository/$dev_id.debug, so repeated runs overwrite
#         the same file instead of littering the repository with one
#         debug file per fetch.
# Change: 20260831a (Rainer) some firmware shows a "Do you want to
#         save current configuration [y/n/^C]?" prompt right after
#         login (observed run together with, and immediately after,
#         the "Press any key to continue" banner on the same line:
#         "Press any key to continueDo you want to save current
#         configuration [y/n/^C]?  "). It was previously unhandled:
#         chat_login's banner loop matched the leading "Press any key
#         to con" text and answered it with a space, which does
#         nothing useful for this prompt, so the session stalled
#         waiting for a real y/n/^C answer until the login timed out
#         - leaving an empty configuration behind (dump_config()
#         always writes a file, even an empty one, when do_fetch's
#         $conf_ref ends up undefined). This prompt is now recognized
#         alongside the banner/menu screens in chat_login and
#         answered with a single raw "y" keystroke (no CR/LF, same
#         convention as the other single-key confirmations here).
#
# The device shell is driven through a pseudo-terminal provided by
# Net::OpenSSH (open2pty), which is then handed to Net::Telnet so all the
# existing prompt-matching / ANSI-stripping logic keeps working. SSH
# authenticates user/password when the connection is opened, so the
# interactive Username:/Password: login exchange is gone; ProCurve still
# shows its "Press any key to continue" banner over SSH, so that (and the
# enable escalation) are retained.
#
#       Handle SW names > 23 char: swi1071w1_swi310505_wan_transf
#
# Change: 20260910 (Rainer) a hostname containing spaces (e.g. "IS Nr
#         337542") left a stray last line in the saved config: the
#         prompt token pattern [\w.-]+ stops at a space, so only the
#         last word ("337542") was learned as the prompt, and the
#         words before it ("IS Nr ") stayed in the prematch as
#         config. The token pattern is now [\w.-]+(?: [\w.-]+)* -
#         words separated by single spaces - in every place the prompt
#         is matched or learned (wait_for_command_prompt callers, the
#         post-match checks, the enable-prompt check), so the whole
#         hostname is learned and quotemeta()'d for the later prompt
#         matches. Words cannot span a newline, so preceding output
#         is not swallowed.
#
# $Id: ProCurveSSH.pm,v 1.2 2026/09/10 18:00:00 tammer Exp $
package fetchconfig::model::ProCurveSSH; # fetchconfig/model/ProCurveSSH.pm
use strict;
use warnings;
use Net::Telnet;
use Net::OpenSSH;
use fetchconfig::model::Abstract;
@fetchconfig::model::ProCurveSSH::ISA = qw(fetchconfig::model::Abstract);
####################################
# Implement model::Abstract - Begin
#
sub label
{
  'procurve-ssh';
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
# There's probably a better way to do this, but this works for now!
# http://en.wikipedia.org/wiki/ANSI_escape_code
# stripansi: shared implementation in model::Abstract since 9.58.
# Wait for the final CLI/enable command prompt, tolerating a "Press
# any key to continue" banner, the built-in ASCII "Main Menu" screen,
# and/or a "Do you want to save current configuration" prompt along
# the way - any of which can appear at unpredictable points in the
# session (see Change: 20260902 below). $prompt_regex is the bare
# prompt pattern (no delimiters), e.g. '([\w.-]+(?: [\w.-]+)* ?)[>#] ' or
# '([\w.-]+(?: [\w.-]+)* ?)# '. $label is used only in log/error messages to
# identify the call site.
# wait_for_command_prompt: shared implementation in model::Abstract since 9.60;
# this model's interruption screens are declared below.

# The screens this switch family interposes before its prompt, and the raw
# keystroke that dismisses each (see Abstract::wait_for_command_prompt):
#  - "Press any key to continue": any key but Return - Return would select
#    the Menu interface (HP/Aruba documentation).
#  - the Menu interface: item 5 is "Command Line (CLI)"; digits execute
#    without Enter.
#  - "Do you want to save current configuration": answer y.
sub interrupt_screens {
  ( ['Press any key to continue',                 ' ', undef],
    ['Main Menu',                                  '5', undef],
    ['Do you want to save current configuration',  'y', 'saved running config'] );
}
sub chat_login {
  my ($self, $t, $dev_id, $dev_host, $dev_opt_tab) = @_;
  my $ok;
  # Under SSH the username and password are supplied when the connection
  # is opened (see do_fetch_ssh), so there is no interactive
  # Username:/Password: exchange. ProCurve/Aruba menu-based switches may
  # still show one or more "Press any key to continue" banners before
  # the CLI prompt, and - if a bare Return is sent to dismiss the last
  # one, or if the switch's configured logon default forces it - the
  # built-in ASCII "Main Menu" screen instead of the CLI. Wait for any
  # of: banner, menu, or command prompt.
  my ($prematch, $match) = $self->wait_for_command_prompt($t, '([\w.-]+(?: [\w.-]+)* ?)[>#] ', "login");
  if (!defined($prematch))
  {
    return undef;
  }
  # --------------------------------------------------------------------------------
  # match the command promt
  $match = fetchconfig::model::Abstract::stripansi($match);   # drop the leading cursor escape(s) before reading the prompt
  if ($match !~ /^(\S+(?: \S+)* ?)[>#] $/)
  {
    $self->log_error("could not match command prompt in [$match]");
    return undef;
  }
  if ($match =~ /^(\S+(?: \S+)* ?)> $/)
  {
    $ok = $t->print('enable');
    if (!$ok)
    {
      $self->log_error("could not send enable command");
      return undef;
    }
    ($prematch, $match) = $t->waitfor(Match => '/Password: /');
    if (!defined($prematch))
    {
      $self->log_error("could not find enable password prompt");
      return undef;
    }
    if ($match =~ /^Password/)
    {
      my $dev_enable = $self->dev_option($dev_opt_tab, "enable");
      if (!defined($dev_enable))
      {
        $self->log_error("enable password needed but not provided");
        return undef;
      }
      $ok = $self->print_secret($t, $dev_enable);
      if (!$ok)
      {
        $self->log_error("could not send enable password");
        return undef;
      }
      ($prematch, $match) = $self->wait_for_command_prompt($t, '([\w.-]+(?: [\w.-]+)* ?)# ', "enable");
      if (!defined($prematch))
      {
        return undef;
      }
    }
    # logged on and foung command prompt
    $self->log_debug("found enable prompt: [$match]");
  }
  # Learn the prompt from the ANSI-STRIPPED match. The switch emits a
  # cursor-home escape (ESC[1H) right before the hostname; ESC is not a
  # word character but "1H" is, so matching the raw buffer swallowed
  # "1HIS Nr 337583" as the hostname. It still "worked" only because the
  # same escape preceded every later prompt - fragile, and it stored a
  # wrong name. Strip first, then capture; the later prompt matches
  # accept an optional escape prefix so the clean name still matches
  # the raw stream (see the (?:\x1b...)* prefix below).
  my $clean = fetchconfig::model::Abstract::stripansi($match);
  if ($clean !~ /([\w.-]+(?: [\w.-]+)* ?)#/)
  {
    $self->log_error("could not match enable command prompt");
    return undef;
  }
  my $prompt = $1;
  $self->{prompt} = $prompt; # save prompt
  $self->log_debug("logged in prompt: [$prompt]");
  # Disable the CLI pager ("no page") here, as the final step of
  # getting into a known, ready-to-fetch state, instead of as
  # chat_fetch's first action (see Change: 20260902 below for why: a
  # stale/echoed prompt-looking string can appear in the banner text
  # before "Press any key to continue" truly completes, and the OLD
  # code's unqualified wait in chat_fetch - right after sending "no
  # page" - had no way to notice if that banner was still pending,
  # letting the "n" of "no page" be consumed as its dismissal
  # keystroke and leaving "o page" rejected as invalid, pager still
  # on - the exact "Invalid input: o" case fixed here in 20260827,
  # but via a fallback in chat_fetch rather than making "no page"
  # itself reliable). Reusing wait_for_command_prompt() here means a
  # "no page" sent too early is recognized and retried through any
  # such leftover banner instead of being silently swallowed.
  $ok = $t->print('no page');
  if (!$ok)
  {
    $self->log_error("could not send pager disabling command");
    return undef;
  }
  ($prematch, $match) = $self->wait_for_command_prompt($t, '(?:\\x1b\\[[\\d;?]*[A-Za-z])*' . quotemeta($prompt) . '# ', "no page");
  return undef unless defined($prematch);
  $prompt;
}
# expect_enable_prompt: inherited from model::Abstract since 9.58. The switch emits cursor
# escapes right before the prompt (ESC[1H, ESC[?25l, ...); prompt_head lets the shared
# matcher consume them as part of the prompt unit. The tail is unanchored "# " as before.
sub prompt_head { '(?:\\x1b\\[[\\d;?]*[A-Za-z])*' }
sub prompt_tail { '# ' }
sub chat_fetch
{
  my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $conf_ref) = @_;
  my $ok;
  # "no page" is now sent - and confirmed via the banner-tolerant
  # wait_for_command_prompt() - as the last step of chat_login above,
  # not here.
  my $show_cmd="show run";
  $ok = $t->print($show_cmd);
  if (!$ok)
  {
    $self->log_error("could not send show run command: $show_cmd");
    return 1;
  }
  # The exact number of echo/banner lines to skip before real config
  # content starts is not reliable across devices/firmware/timing (see
  # Change: 20260902b below) - rather than guess a fixed count here,
  # everything is captured and trimmed below, anchored on the first
  # line that actually looks like configuration content.
  my $save_timeout;
  if (defined($fetch_timeout))
  {
    $save_timeout = $t->timeout;
    $t->timeout($fetch_timeout);
  }
  # Accumulate "show run" output across pagination. Regardless of
  # whether "no page" above was actually accepted by the switch, treat
  # "-- MORE --" as an interstitial prompt: dismiss it with a raw
  # space and keep waiting, the same pattern chat_login uses for
  # banners/menus. Bounded so a genuinely wedged pager still fails
  # instead of running out the whole fetch_timeout silently.
  my $prompt_regexp = '(?:\\x1b\\[[\\d;?]*[A-Za-z])*' . quotemeta($prompt) . '# ';
  my $more_regexp   = '-- ?MORE ?--';
  my $full_config   = '';
  my $more_retries  = 200; # generous: large configs can page many times
  my ($prematch, $match);
  while (1)
  {
    ($prematch, $match) = $t->waitfor(Match => "/$prompt_regexp|$more_regexp/");
    if (!defined($prematch))
    {
      $self->log_error("could not find end of configuration (or MORE prompt)");
      if (defined($fetch_timeout))
      {
        $t->timeout($save_timeout);
      }
      return 1;
    }
    $full_config .= $prematch;
    last if $match =~ /$prompt_regexp/;
    if ($more_retries-- <= 0)
    {
      $self->log_error("too many MORE pagination pages, giving up");
      if (defined($fetch_timeout))
      {
        $t->timeout($save_timeout);
      }
      return 1;
    }
    $self->log_debug("paging through MORE prompt");
    my $ok2 = $t->put(" ");
    if (!$ok2)
    {
      $self->log_error("could not send space to page through MORE prompt");
      if (defined($fetch_timeout))
      {
        $t->timeout($save_timeout);
      }
      return 1;
    }
  }
  if (defined($fetch_timeout))
  {
    $t->timeout($save_timeout);
  }
  $self->log_debug("found end of configuration: [" . fetchconfig::model::Abstract::stripansi($match) . "]");
  foreach my $line (split /\n/, $full_config)
  {
    my $ascii_line=fetchconfig::model::Abstract::stripansi($line);
    # Drop the pager's own status line - terminal chrome, not device
    # config, that can appear mid-page when "show run" is paginated
    # (see MORE-handling loop above).
    next if $ascii_line =~ /-- ?MORE ?--/ || $ascii_line =~ /next page:\s*Space/;
    chomp $ascii_line;
    push(@$conf_ref,$ascii_line ? $ascii_line : "");
  }
  # Remove ANSI fragment from final line (if present)
  $conf_ref->[$#$conf_ref]=~s/\x1b\[24\;//;
  # Change: 20260902b (Rainer) real ProCurve config content always
  # starts with a line beginning with "; " (e.g. "; J9049A
  # Configuration Editor; Created on release #T.13.84"); everything
  # before that is echo/banner noise from "show run" itself (the
  # command echo, the "Running configuration:" header, a blank line,
  # etc.). The exact noise line count is not reliable across devices/
  # firmware/timing - a fixed "discard exactly 3 lines via getline()"
  # (the old approach) could discard too few (leaving a stray leading
  # blank line in the saved backup) or too many (silently eating the
  # config's real first line) depending on the day. Trimming up to
  # (but not including) the first "; "-prefixed line is exact instead
  # of a guess.
  my $noise_lines = 0;
  while (@$conf_ref && $conf_ref->[0] !~ /^; /)
  {
    $noise_lines++;
    shift @$conf_ref;
  }
  if (@$conf_ref)
  {
    $self->log_debug("dropped $noise_lines leading noise line(s) before start of configuration") if $noise_lines;
  }
  else
  {
    $self->log_error("could not find start of configuration (no line starting with '; ' seen)");
    return 1;
  }
  # Defensive cleanup: over an SSH pty the switch redraws its prompt with
  # extra terminal control codes, so a leftover prompt line (e.g.
  # "W_B1_41_SW1" or "W_B1_41_SW1#") and/or trailing blank lines can end
  # up appended to the config. Drop trailing blanks, then a single
  # trailing line that is just the command prompt.
  while (@$conf_ref && $conf_ref->[$#$conf_ref] =~ /^\s*$/)
  {
    pop @$conf_ref;
  }
  if (@$conf_ref && $conf_ref->[$#$conf_ref] =~ /^\s*\Q$prompt\E\s*[>#]?\s*$/)
  {
    pop @$conf_ref;
  }
  # Drop any blank lines exposed by removing the prompt line
  while (@$conf_ref && $conf_ref->[$#$conf_ref] =~ /^\s*$/)
  {
    pop @$conf_ref;
  }
#  # Debugging code for line-by-line analysis
#  for(my $i=0;$i<(scalar @$conf_ref);$i++)
#  {
#    if((my $line_len=length $conf_ref->[$i]) >1)
#    {
#      $self->log_debug("[L " . $i . "-" . (length $conf_ref->[$i]) . "] " . $conf_ref->[$i]);
#    }
#  }
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

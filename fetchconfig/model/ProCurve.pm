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
# Change: 20260821a (Rainer) fix hostname prompt regex to allow '_' and '.'
#         (was [A-Za-z0-9-], missed underscores in hostnames like
#         swi11031_swi316411, causing the captured $prompt to be truncated
#         to only the tail of the hostname). Added quotemeta() when the
#         captured prompt is interpolated back into a live regex in
#         expect_enable_prompt, so prompts containing regex metacharacters
#         (e.g. '.') can't cause a similar partial-match/truncation bug.
# Change: 20260821b (Rainer) some ProCurve/Aruba firmware shows the
#         "Press any key to continue" banner more than once before the
#         Username:/Password: login sequence, and sending a bare Return
#         to dismiss it - as the old $t->print("") did - is documented
#         HP/Aruba behavior for selecting the built-in ASCII Menu
#         interface instead of continuing the normal login. The single
#         "hit a key, then expect Username:" step is now a bounded loop
#         that dismisses repeated banners with a raw space (put(" "),
#         no CR/LF) and, as a safety net, detects a "Main Menu" screen
#         and selects "5. Command Line (CLI)" to get back on track. The
#         duplicate Username:/Password: handling that used to live
#         inside the old single-shot banner check was removed - it's
#         now handled once, by the pre-existing "direct Username:"
#         block below, which every login path (banner or not) falls
#         through into.
# Change: 20260821c (Rainer) the "Press any key to continue" banner
#         can also appear *after* a successful Username:/Password:
#         login (right after the "Your previous successful login..."
#         notice), not only before it. Every place that waits for the
#         final CLI/enable prompt now goes through a new helper,
#         wait_for_command_prompt(), which tolerates that post-login
#         banner (and, defensively, a "Main Menu" screen) exactly the
#         same way the pre-login banner is handled above, instead of
#         timing out with "could not find command prompt (pw)".
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
#         configuration [y/n/^C]?  "). It was previously
#         unhandled: wait_for_command_prompt's banner loop matched
#         the leading "Press any key to continue" text and answered it
#         with a space, which does nothing useful for this prompt,
#         so the session stalled waiting for a real y/n/^C answer
#         until the login timed out - leaving an empty configuration
#         behind (dump_config() always writes a file, even an empty
#         one, when do_fetch's $conf_ref ends up undefined). This
#         prompt is now recognized alongside the banner/menu screens
#         in wait_for_command_prompt and answered with a single raw
#         "y" keystroke (no CR/LF, same convention as the other
#         single-key confirmations here).
# Change: 20260902 (Rainer) putty log from a J9049A (T.13.84) showed
#         the CLI prompt itself ("V4-SW1# ") appearing in the banner
#         text BEFORE "Press any key to continue" had actually been
#         dealt with: "...Press any key to continueV4-SW1# show run".
#         wait_for_command_prompt's combined regex has no way to tell
#         a genuinely-ready prompt from this kind of premature/stale
#         echo - whichever alternative appears earliest in the
#         buffer wins, regardless of which one is semantically final.
#         Previously "no page" was chat_fetch's first action, checked
#         with a plain, non-banner-tolerant wait: if the device was
#         still catching up on its banner at that moment, the "n" of
#         "no page" could be consumed as the "Press any key" banner's
#         own dismissal keystroke, leaving "o page" sent to the
#         resulting prompt as an invalid command - pager still
#         enabled. (The sibling ProCurveSSH.pm hit this exact
#         "Invalid input: o" symptom before, fixed there in 20260827
#         by tolerating "-- MORE --" as a fallback; this module has no
#         such fallback in chat_fetch, so a corrupted "no page" here
#         would instead stall until fetch_timeout - all the more
#         reason to make "no page" itself reliable.) "no page" is now sent (and
#         confirmed) at the end of chat_login_telnet itself, via the
#         same banner/menu/save-prompt tolerant wait_for_command_prompt()
#         already used for login, so a "no page" sent into a still-
#         settling session is retried through any leftover banner
#         instead of being silently swallowed.
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
# $Id: ProCurve.pm,v 9.7 2026/09/10 18:00:00 tammer Exp $

package fetchconfig::model::ProCurve; # fetchconfig/model/ProCurve.pm
use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract;
@fetchconfig::model::ProCurve::ISA = qw(fetchconfig::model::Abstract);
####################################
# Implement model::Abstract - Begin
#
sub label
{
  'procurve';
}
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
# Wait for the final CLI/enable command prompt, tolerating a
# "Press any key to continue" banner and/or the built-in ASCII "Main
# Menu" screen along the way - either of which can appear right after a
# successful Username:/Password: (or enable-password) exchange, not
# only before it. $prompt_regex is the bare prompt pattern (no
# delimiters), e.g. '([\w.-]+(?: [\w.-]+)* ?)[>#] ' or '([\w.-]+(?: [\w.-]+)* ?)# '. $label is
# used only in log/error messages to identify the call site.
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
sub chat_login_telnet {
  my ($self, $t, $dev_id, $dev_host, $dev_opt_tab) = @_;
  my $ok;
  # ProCurve/Aruba menu-based switches may show one or more "Press any
  # key to continue" banners before the Username:/Password: login
  # sequence, and - if a bare Return is sent to dismiss the last one,
  # or if the switch's configured logon default forces it - the
  # built-in ASCII "Main Menu" screen instead. Wait for any of: banner,
  # menu, or the actual login prompts.
  my $combined_login_match = '/Password: |Username: |Press any key to continue|Main Menu/';
  my ($prematch, $match) = $t->waitfor(Match => $combined_login_match);
  if (!defined($prematch))
  {
    $self->log_error("could not find login prompt");
    return undef;
  }
  else
  {
    $self->log_debug("found login prompt: [$match]");
  }
  # --------------------------------------------------------------------------------
  # Dismiss banners and/or escape the Menu interface until the
  # Username:/Password: login sequence appears, bounded by a retry
  # limit so a genuinely stuck session still fails instead of looping
  # forever. IMPORTANT: do not send a bare Return to dismiss "Press any
  # key to continue" - HP/Aruba documents that Return specifically
  # selects the Menu interface, while any other key drops straight into
  # the login sequence/CLI.
  my $banner_retries = 8;
  while ($match =~ /Press any key to continue/ || $match =~ /Main Menu/)
  {
    if ($banner_retries-- <= 0)
    {
      $self->log_error("too many banner/menu screens, giving up");
      return undef;
    }
    if ($match =~ /Press any key to continue/)
    {
      # put() sends the byte raw, with no trailing CR/LF - unlike the
      # old print(""), which appended a Return via
      # Output_record_separator (defaulting to "\n", but any Enter-like
      # keystroke risks the same Menu-selection behavior on firmware
      # that treats it that way).
      $ok = $t->put(" ");
      if (!$ok)
      {
        $self->log_error("could not send any key");
        return undef;
      }
    }
    else # Main Menu
    {
      # Landed in the Menu anyway (forced logon default, or an
      # unexpected extra banner) - select item 5, "Command Line
      # (CLI)", to drop back to the CLI/login sequence. Menu items
      # execute on the digit alone; no Enter is needed.
      $ok = $t->put("5");
      if (!$ok)
      {
        $self->log_error("could not select Command Line (CLI) from menu");
        return undef;
      }
    }
    ($prematch, $match) = $t->waitfor(Match => $combined_login_match);
    if (!defined($prematch))
    {
      $self->log_error("could not find login prompt after banner/menu");
      return undef;
    }
    else
    {
      $self->log_debug("found login prompt: [$match]");
    }
  }
  # --------------------------------------------------------------------------------
  # direct Username:
  if ($match =~ /^Username: /)
  {
    my $dev_user = $self->dev_option($dev_opt_tab, "user");
    if (!defined($dev_user))
    {
      $self->log_error("login user needed but not provided");
      return undef;
    }
    $ok = $t->print($dev_user);
    if (!$ok)
    {
      $self->log_error("could not send login user");
      return undef;
    }
    else
    {
      $self->log_debug("send login user OK");
    }
    ($prematch, $match) = $t->waitfor(Match => '/Password: /', Timeout => 2);
    if (!defined($prematch))
    {
      $self->log_error("could not find password prompt - case 2");
      return undef;
    }
    $self->log_debug("found password prompt: [$match]");
    if ($match =~ /^Password: /)
    {
      my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
      if (!defined($dev_pass))
      {
        $self->log_error("login password needed but not provided");
        return undef;
      }
      else
      {
        $self->log_debug("send login password OK");
      }
      $ok = $self->print_secret($t, $dev_pass);
      if (!$ok)
      {
        $self->log_error("could not send login password");
        return undef;
      }
      ($prematch, $match) = $self->wait_for_command_prompt($t, '([\w.-]+(?: [\w.-]+)* ?)[>#] ', "pw");
      if (!defined($prematch))
      {
        return undef;
      }
      else
      {
        # Note that below line may not appear properly due to the escape sequences from the switch
        $self->log_debug("found command prompt: [" . fetchconfig::model::Abstract::stripansi($match) . "]");
      }
    }
  }
  # --------------------------------------------------------------------------------
  # direct login:
  if ($match =~ /login: $/)
  {
    my $dev_user = $self->dev_option($dev_opt_tab, "user");
    if (!defined($dev_user))
    {
      $self->log_error("login username needed but not provided");
      return undef;
    }
    $ok = $t->print($dev_user);
    if (!$ok)
    {
      $self->log_error("could not send login username");
      return undef;
    }
    ($prematch, $match) = $t->waitfor(Match => '/Password: $/');
    if (!defined($prematch))
    {
      $self->log_error("could not find password prompt - case 3");
      return undef;
    }
    $self->log_debug("found password prompt: [$match]");
  }
  # login with only password
  if ($match =~ /^Password: /)
  {
    my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
    if (!defined($dev_pass))
    {
      $self->log_error("login password needed but not provided");
      return undef;
    }
    $ok = $self->print_secret($t, $dev_pass);
    if (!$ok)
    {
      $self->log_error("could not send login password");
      return undef;
    }
    ($prematch, $match) = $self->wait_for_command_prompt($t, '([\w.-]+(?: [\w.-]+)* ?)[>#] ', "pw");
    if (!defined($prematch))
    {
      return undef;
    }
    else
    {
      # Note that below line may not appear properly due to the escape sequences from the switch
      $self->log_debug("found command prompt: [" . fetchconfig::model::Abstract::stripansi($match) . "]");
    }
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
  # chat_fetch's first action (see Change: 20260902 above for why:
  # a stale/echoed prompt-looking string can appear in the banner
  # text before "Press any key to continue" truly completes, and the
  # OLD code's unqualified wait in chat_fetch - right after sending
  # "no page" - had no way to notice if that banner was still
  # pending, letting the "n" of "no page" be consumed as its
  # dismissal keystroke and leaving "o page" rejected as invalid,
  # pager still on). Reusing wait_for_command_prompt() here means a
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
  # wait_for_command_prompt() - as the last step of chat_login_telnet
  # above, not here.
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
  my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt);
  if (!defined($prematch))
  {
    $self->log_error("could not find end of configuration");
    return 1;
  }
  if (defined($fetch_timeout))
  {
    $t->timeout($save_timeout);
  }
  $self->log_debug("found end of configuration: [" . fetchconfig::model::Abstract::stripansi($match) . "]");
  foreach my $line (split /\n/, $prematch)
  {
    my $ascii_line=fetchconfig::model::Abstract::stripansi($line);
    chomp $ascii_line;
    push(@$conf_ref,$ascii_line ? $ascii_line : "");
  }
  # Remove ANSI fragment from final line (if present). Guard the empty
  # case: a switch that answers "show run" with nothing but its prompt
  # (or a mock that does) used to crash here ("Modification of
  # non-creatable array value attempted, subscript -1") instead of the
  # fetch simply failing further down as an empty configuration.
  $conf_ref->[$#$conf_ref]=~s/\x1b\[24\;// if @$conf_ref;
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
sub do_fetch_telnet
{
  my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;
  my $dev_timeout = $self->dev_option($dev_opt_tab, "timeout");
  my @telnet_args = (Errmode => 'return', Timeout => $dev_timeout, Output_field_separator => "\r\n");
  # Record the raw session for debugging. Written under the
  # device's own repository (same place its config backups live)
  # instead of a fixed, shared, world-readable /tmp path: avoids
  # leaking credentials/config to other local users and avoids a
  # predictable-filename symlink-attack target in /tmp. Off by
  # default; enable per-device with "debug=on" in the device table.
  my $dev_repository = $self->dev_option($dev_opt_tab, "repository");
  if (defined($dev_repository) && $self->dev_option_flag($dev_opt_tab, "debug", 0)) {
    push @telnet_args, (dump_log => "$dev_repository/$dev_id.debug");
  }
  my $t = new Net::Telnet(@telnet_args);
  # dump_log records the session verbatim, credentials included -> 0600.
  # Net::Telnet opened the file in new(), so restrict it by path now.
  $self->secure_debug_file("$dev_repository/$dev_id.debug")
    if $self->dev_option_flag($dev_opt_tab, "debug", 0);
  my $ok = $t->open($dev_host);
  if (!$ok)
  {
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
  if (!$ok)
  {
    $self->log_error("disconnecting: $!");
  }
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
  $conf_ref=$self->do_fetch_telnet($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab);
  $self->log_debug("disconnected");
  # do_fetch_telnet returns undef on any login/fetch failure (see its
  # early "return;" points above). Belt-and-suspenders alongside the
  # same check now in Abstract::dump_config(): don't even attempt to
  # save, consistent with every other model's do_fetch().
  return unless defined($conf_ref);
  $self->dump_config($dev_id, $dev_opt_tab, $conf_ref);
}
1;
